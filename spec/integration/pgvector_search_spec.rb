# frozen_string_literal: true

require "rails_helper"
require "maglev/chunk"
require "maglev/retriever"

class PgvectorSearchOwner < ActiveRecord::Base
  self.table_name = "pgvector_search_owners"
end

class FixedPgvectorEmbeddingAdapter
  def initialize(embedding)
    @embedding = embedding
  end

  def maglev_adapter_id = "test.pgvector_search"

  def maglev_adapter_version = "1"

  def embed(_text)
    @embedding
  end
end

RSpec.describe "pgvector semantic search" do
  around do |example|
    unless pgvector_available?
      skip "PostgreSQL with pgvector is not available; CI requires this integration test"
    end

    original = Maglev.configuration
    configuration = Maglev::Configuration.new
    configuration.embedding_dimensions = 3
    Maglev.instance_variable_set(:@configuration, configuration)
    connection = ActiveRecord::Base.connection
    connection.create_table(:maglev_chunks, force: true) do |t|
      t.string :owner_type, null: false
      t.bigint :owner_id, null: false
      t.string :owner_model_name, null: false
      t.string :source, null: false
      t.integer :chunk_index, null: false
      t.text :content, null: false
      t.string :content_checksum, null: false
      t.string :embedding_model, null: false
      t.string :index_version, limit: 64
      t.vector :embedding, limit: 3, null: false
      t.timestamps
    end
    connection.create_table(:pgvector_search_owners, force: true) do |t|
      t.string :name, null: false
      t.timestamps
    end

    connection.add_index :maglev_chunks, :embedding, using: :hnsw, opclass: :vector_cosine_ops
    example.run
  ensure
    Maglev.instance_variable_set(:@configuration, original) if original
    connection&.drop_table(:maglev_chunks, if_exists: true)
    connection&.drop_table(:pgvector_search_owners, if_exists: true)
  end

  it "executes a nearest-neighbor query and returns typed results" do
    adapter = FixedPgvectorEmbeddingAdapter.new([1.0, 0.0, 0.0])
    current_version = Maglev::IndexIdentity.new(
      configuration: Maglev.configuration,
      adapter: adapter,
      chunk_size: Maglev.configuration.chunk_size
    ).to_s
    owner = PgvectorSearchOwner.create!(name: "Acme")
    farther_owner = PgvectorSearchOwner.create!(name: "Beta")
    legacy_owner = PgvectorSearchOwner.create!(name: "Legacy")
    Maglev::Chunk.create!(
      owner_type: "PgvectorSearchOwner",
      owner_id: owner.id,
      owner: owner,
      owner_model_name: "PgvectorSearchOwner",
      source: "snapshot",
      chunk_index: 0,
      content: "closest",
      content_checksum: "a",
      embedding_model: "fake",
      index_version: current_version,
      embedding: [1.0, 0.0, 0.0]
    )
    Maglev::Chunk.create!(
      owner_type: "PgvectorSearchOwner",
      owner_id: farther_owner.id,
      owner: farther_owner,
      owner_model_name: "PgvectorSearchOwner",
      source: "snapshot",
      chunk_index: 0,
      content: "farther",
      content_checksum: "b",
      embedding_model: "fake",
      index_version: "b" * 64,
      embedding: [1.0, 0.0, 0.0]
    )
    Maglev::Chunk.create!(
      owner_type: "PgvectorSearchOwner",
      owner_id: legacy_owner.id,
      owner: legacy_owner,
      owner_model_name: "PgvectorSearchOwner",
      source: "snapshot",
      chunk_index: 0,
      content: "legacy-null",
      content_checksum: "c",
      embedding_model: "fake",
      index_version: nil,
      embedding: [1.0, 0.0, 0.0]
    )

    results = Maglev::Retriever.new(PgvectorSearchOwner, embedding_adapter: adapter).search("nearest", limit: 3)

    expect(results.map(&:owner)).to eq([owner])
    expect(results.first).to be_a(Maglev::SearchResult)
    expect(results.first.content).to eq("closest")
  end

  it "applies authorization, accepts the threshold boundary, and returns multiple chunks per stable owner" do
    adapter = FixedPgvectorEmbeddingAdapter.new([1.0, 0.0, 0.0])
    version = current_version(adapter)
    allowed = PgvectorSearchOwner.create!(name: "Allowed")
    denied = PgvectorSearchOwner.create!(name: "Denied")
    create_chunk(allowed, index: 0, content: "allowed-0", embedding: [1.0, 0.0, 0.0], version: version)
    create_chunk(allowed.reload, index: 1, content: "allowed-1", embedding: [1.0, 0.0, 0.0], version: version)
    create_chunk(denied, index: 0, content: "denied", embedding: [1.0, 0.0, 0.0], version: version)
    authorization_adapter = Class.new do
      define_method(:scope) { |model:, user:| model.where(id: user.fetch(:owner_ids)) }
      define_method(:authorize) { |record:, user:| user.fetch(:owner_ids).include?(record.id) }
    end.new

    sql = []
    subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      sql << payload[:sql] if payload[:sql].include?("maglev_chunks")
    end
    outcome = Maglev::Retriever.new(
      PgvectorSearchOwner,
      embedding_adapter: adapter,
      authorization: Maglev::Authorization.new(adapter: authorization_adapter)
    ).retrieval_outcome(
      "nearest",
      limit: 1,
      user: {owner_ids: [allowed.id]},
      minimum_similarity: 1.0,
      chunks_per_owner: 2
    )

    expect(outcome.results.map(&:content)).to eq(%w[allowed-0 allowed-1])
    expect(outcome.results.map { |result| [result.owner.class.name, result.owner.id] }.uniq).to eq([["PgvectorSearchOwner", allowed.id]])
    expect(outcome).to have_attributes(examined_count: 2, accepted_count: 2, rejected_count: 0)
    expect(sql).to include(match(/LIMIT (?:\$\d+|4)/))
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  def current_version(adapter)
    Maglev::IndexIdentity.new(
      configuration: Maglev.configuration,
      adapter: adapter,
      chunk_size: Maglev.configuration.chunk_size
    ).to_s
  end

  def create_chunk(owner, index:, content:, embedding:, version:)
    Maglev::Chunk.create!(
      owner_type: "PgvectorSearchOwner",
      owner_id: owner.id,
      owner: owner,
      owner_model_name: "PgvectorSearchOwner",
      source: "snapshot",
      chunk_index: index,
      content: content,
      content_checksum: Digest::SHA256.hexdigest(content),
      embedding_model: "fake",
      index_version: version,
      embedding: embedding
    )
  end

  def pgvector_available?
    connection = ActiveRecord::Base.connection
    connection.enable_extension("vector")
    connection.extension_enabled?("vector")
  rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::StatementInvalid, PG::Error
    raise if ENV["MAGLEV_REQUIRE_POSTGRESQL"] == "true"

    false
  end
end
