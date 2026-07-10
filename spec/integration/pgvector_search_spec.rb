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

  def embed(_text)
    @embedding
  end
end

RSpec.describe "pgvector semantic search" do
  around do |example|
    unless pgvector_available?
      skip "PostgreSQL with pgvector is not available; CI requires this integration test"
    end

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
    connection&.drop_table(:maglev_chunks, if_exists: true)
    connection&.drop_table(:pgvector_search_owners, if_exists: true)
  end

  it "executes a nearest-neighbor query and returns typed results" do
    owner = PgvectorSearchOwner.create!(name: "Acme")
    farther_owner = PgvectorSearchOwner.create!(name: "Beta")
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
      embedding: [0.0, 1.0, 0.0]
    )

    results = Maglev::Retriever.new(PgvectorSearchOwner, embedding_adapter: FixedPgvectorEmbeddingAdapter.new([1.0, 0.0, 0.0])).search("nearest", limit: 1)

    expect(results.first).to be_a(Maglev::SearchResult)
    expect(results.first.owner.id).to eq(owner.id)
    expect(results.first.content).to eq("closest")
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
