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
  attr_reader :calls
  attr_accessor :maglev_adapter_version

  def initialize(version: "1")
    @maglev_adapter_version = version
    @calls = []
  end

  def maglev_adapter_id = "test.vector_store_embedding"

  def embed(_text)
    @calls << true
    [1.0, 0.0]
  end
end

class RecordingVectorStore
  attr_reader :fetch_calls, :replace_calls

  def initialize
    @store = Maglev::VectorStores::Memory.new
    @fetch_calls = []
    @replace_calls = []
  end

  def fetch(ids:)
    materialized = ids.to_a
    @fetch_calls << materialized
    @store.fetch(ids: materialized)
  end

  def replace_owner(owner_type:, owner_id:, documents:)
    materialized = documents.to_a
    @replace_calls << [owner_type, owner_id, materialized]
    @store.replace_owner(owner_type: owner_type, owner_id: owner_id, documents: materialized)
  end

  def delete_by_owner(*) = raise "unexpected delete_by_owner"
  def upsert(*) = raise "unexpected upsert"
end

RSpec.describe "Vector store backed indexing and retrieval" do
  around do |example|
    original = Maglev.configuration
    Maglev.instance_variable_set(:@configuration, Maglev::Configuration.new)
    example.run
  ensure
    Maglev.instance_variable_set(:@configuration, original)
  end

  it "unindexes through a configured store without accessing the chunk model" do
    store = instance_double(Maglev::VectorStores::Base)
    allow(store).to receive(:delete_by_owner)
    chunk_model = Class.new do
      def self.where(*) = raise "chunk access"
    end
    record = VectorStoreIndexedRecord.new(id: 7, name: "Acme")

    Maglev::Indexer.new(record, vector_store: store, chunk_model: chunk_model).unindex

    expect(store).to have_received(:delete_by_owner).with(owner_type: "VectorStoreIndexedRecord", owner_id: 7)
  end

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
      embedding_adapter: VectorStoreEmbeddingAdapter.new,
      embedding_dimensions: 2
    ).search("acme", limit: 1)

    expect(results.first.owner).to be(record)
    expect(results.first.content).to include("name: Acme")
    expect(results.first.source).to eq("snapshot")
  end

  it "reuses custom-store embeddings only for matching content and complete identity" do
    store = Maglev::VectorStores::Memory.new
    record = VectorStoreIndexedRecord.new(id: 7, name: "Acme")
    adapter = VectorStoreEmbeddingAdapter.new

    2.times { index_record(record, store, adapter) }

    document = store.fetch(ids: ["VectorStoreIndexedRecord:7:snapshot:0"]).first
    expect(adapter.calls.size).to eq(1)
    expect(document.index_version).to eq(custom_index_version(adapter))
  end

  it "fetches and atomically replaces a complete multi-chunk generation once per index" do
    store = RecordingVectorStore.new
    record = VectorStoreIndexedRecord.new(id: 7, name: "Acme with enough content for several chunks")
    adapter = VectorStoreEmbeddingAdapter.new

    2.times { index_record(record, store, adapter, chunk_size: 20) }

    first_ids = store.fetch_calls.first
    expect(first_ids.size).to be > 1
    expect(store.fetch_calls).to eq([first_ids, first_ids])
    expect(store.replace_calls.size).to eq(2)
    expect(store.replace_calls.map { |_type, _id, documents| documents.map(&:id) }).to eq([first_ids, first_ids])
    expect(adapter.calls.size).to eq(first_ids.size)
  end

  it "re-embeds custom-store content when each index identity component changes" do
    record = VectorStoreIndexedRecord.new(id: 7, name: "Acme")

    expect_custom_identity_change(record) { Maglev.configuration.embedding_model = "changed-model" }
    expect_custom_identity_change(record, second_dimensions: 3) {}
    expect_custom_identity_change(record) { |adapter| adapter.maglev_adapter_version = "2" }
    expect_custom_identity_change(record) { stub_const("Maglev::Chunker::ALGORITHM_VERSION", "2") }
    expect_custom_identity_change(record, second_chunk_size: 1001) {}
    expect_custom_identity_change(record) { Maglev.configuration.application_index_version = "2" }
  end

  it "does not reuse a custom-store legacy document with a null index version" do
    store = Maglev::VectorStores::Memory.new
    record = VectorStoreIndexedRecord.new(id: 7, name: "Acme")
    adapter = VectorStoreEmbeddingAdapter.new
    legacy = Maglev::VectorStores::Document.new(
      owner_type: "VectorStoreIndexedRecord", owner_id: 7, owner_model_name: "VectorStoreIndexedRecord",
      source: "snapshot", chunk_index: 0, content: record.maglev_snapshot,
      content_checksum: Digest::SHA256.hexdigest(record.maglev_snapshot), embedding_model: "legacy",
      index_version: nil, embedding: [1.0, 0.0], owner: record
    )
    store.upsert(documents: [legacy])

    index_record(record, store, adapter)

    expect(adapter.calls.size).to eq(1)
    expect(store.fetch(ids: [legacy.id]).first.index_version).to eq(custom_index_version(adapter))
  end

  def index_record(record, store, adapter, dimensions: 2, chunk_size: 1000)
    Maglev::Indexer.new(
      record,
      vector_store: store,
      embedding_adapter: adapter,
      embedding_dimensions: dimensions,
      chunk_size: chunk_size
    ).index
  end

  def expect_custom_identity_change(record, second_dimensions: 2, second_chunk_size: 1000)
    store = Maglev::VectorStores::Memory.new
    adapter = VectorStoreEmbeddingAdapter.new
    index_record(record, store, adapter)

    yield adapter
    if second_dimensions != 2
      allow(adapter).to receive(:embed).and_wrap_original do |method, text|
        value = method.call(text)
        (value + [0.0]).first(second_dimensions)
      end
    end
    index_record(record, store, adapter, dimensions: second_dimensions, chunk_size: second_chunk_size)

    expect(adapter.calls.size).to eq(2)
    Maglev.instance_variable_set(:@configuration, Maglev::Configuration.new)
  end

  def custom_index_version(adapter)
    configuration = Maglev.configuration
    original_dimensions = configuration.embedding_dimensions
    configuration.embedding_dimensions = 2
    Maglev::IndexIdentity.new(configuration: configuration, adapter: adapter, chunk_size: 1000).to_s
  ensure
    configuration.embedding_dimensions = original_dimensions
  end
end
