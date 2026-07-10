# frozen_string_literal: true

require "spec_helper"
require "maglev/indexer"
require "maglev/knowledge_config"
require "maglev/retriever"
require "maglev/snapshot_builder"
require "maglev/vector_stores/memory"

class VectorStoreIndexedRecord
  attr_accessor :id, :name

  def self.name = "VectorStoreIndexedRecord"

  def self.maglev_config
    @maglev_config ||= Maglev::KnowledgeConfig.build(self) do
      expose :name
    end
  end

  def self.attribute_names
    %w[id name]
  end

  def initialize(id:, name:)
    @id = id
    @name = name
  end

  def maglev_snapshot
    Maglev::SnapshotBuilder.new(self, self.class.maglev_config).build.to_s
  end
end

class VectorStoreEmbeddingAdapter
  def embed(_text)
    [1.0, 0.0]
  end
end

RSpec.describe "Vector store backed indexing and retrieval" do
  it "indexes and retrieves through a configured vector store without ActiveRecord chunk access" do
    store = Maglev::VectorStores::Memory.new
    record = VectorStoreIndexedRecord.new(id: 7, name: "Acme")

    Maglev::Indexer.new(
      record,
      vector_store: store,
      embedding_adapter: VectorStoreEmbeddingAdapter.new,
      embedding_dimensions: 2
    ).index

    results = Maglev::Retriever.new(
      VectorStoreIndexedRecord,
      vector_store: store,
      embedding_adapter: VectorStoreEmbeddingAdapter.new
    ).search("acme", limit: 1)

    expect(results.first.owner).to be(record)
    expect(results.first.content).to include("name: Acme")
    expect(results.first.source).to eq("snapshot")
  end
end
