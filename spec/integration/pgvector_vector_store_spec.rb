# frozen_string_literal: true

require "rails_helper"
require "maglev/vector_stores/document"
require "maglev/vector_stores/pgvector"

class PgvectorStoreOwner < ActiveRecord::Base
  self.table_name = "pgvector_store_owners"
end

RSpec.describe "Pgvector vector store adapter" do
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
      t.vector :embedding, limit: 2, null: false
      t.timestamps
    end
    connection.create_table(:pgvector_store_owners, force: true) do |t|
      t.string :name
      t.timestamps
    end
    connection.add_index :maglev_chunks, :embedding, using: :hnsw, opclass: :vector_cosine_ops
    connection.clear_cache!
    Maglev::Chunk.reset_column_information
    example.run
  ensure
    connection&.drop_table(:maglev_chunks, if_exists: true)
    connection&.drop_table(:pgvector_store_owners, if_exists: true)
  end

  it "upserts, searches with metadata filters, and deletes documents" do
    owner = PgvectorStoreOwner.create!(name: "Acme")
    other_owner = PgvectorStoreOwner.create!(name: "Beta")
    store = Maglev::VectorStores::Pgvector.new
    store.upsert(documents: [
      document_for(owner, content: "risk", checksum: "a", embedding: [1.0, 0.0]),
      document_for(other_owner, content: "safe", checksum: "b", embedding: [0.0, 1.0])
    ])

    results = store.search(vector: [1.0, 0.0], filters: {owner_model_name: "PgvectorStoreOwner"}, limit: 2)
    filtered = store.search(vector: [1.0, 0.0], filters: {owner_model_name: "PgvectorStoreOwner", owner_id: other_owner.id}, limit: 2)

    expect(results.map(&:owner_id)).to eq([owner.id, other_owner.id])
    expect(filtered.map(&:owner_id)).to eq([other_owner.id])
    expect(store.healthcheck).to eq(:ok)
    expect(store.capabilities).to include(:metadata_filtering, :pgvector)

    store.delete_by_owner(owner_type: "PgvectorStoreOwner", owner_id: owner.id)
    expect(store.search(vector: [1.0, 0.0], filters: {owner_model_name: "PgvectorStoreOwner"}, limit: 2).map(&:owner_id))
      .to eq([other_owner.id])
  end

  def document_for(owner, content:, checksum:, embedding:)
    Maglev::VectorStores::Document.new(
      owner_type: "PgvectorStoreOwner",
      owner_id: owner.id,
      owner_model_name: "PgvectorStoreOwner",
      owner: owner,
      source: "snapshot",
      chunk_index: 0,
      content: content,
      content_checksum: checksum,
      embedding_model: "fake",
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
