# frozen_string_literal: true

require "spec_helper"
require "maglev/indexer"
require "maglev/knowledge_config"

class FakeIndexedRecord
  ATTRIBUTES = %w[id name description].freeze

  attr_accessor :id, :name, :description

  def self.attribute_names
    ATTRIBUTES
  end

  def self.name
    "FakeIndexedRecord"
  end

  def self.maglev_config
    @maglev_config ||= Maglev::KnowledgeConfig.build(self) do
      expose :name, :description
    end
  end

  def initialize(id:, name:, description:)
    @id = id
    @name = name
    @description = description
  end

  def maglev_snapshot
    Maglev::SnapshotBuilder.new(self, self.class.maglev_config).build.to_s
  end
end

class FakeEmbeddingAdapter
  attr_reader :calls
  attr_accessor :maglev_adapter_version

  def initialize(dimensions:, version: "1")
    @dimensions = dimensions
    @maglev_adapter_version = version
    @calls = []
  end

  def maglev_adapter_id = "test.fake_embedding"

  def embed(text)
    @calls << text
    Array.new(@dimensions, 0.1)
  end
end

class FakeChunk
  class << self
    attr_reader :rows

    def reset!
      @rows = []
    end

    def transaction
      yield
    end

    def where(conditions)
      Scope.new(@rows, conditions)
    end

    def create!(attributes)
      @rows << attributes
    end
  end

  class Scope
    def initialize(rows, conditions)
      @rows = rows
      @conditions = conditions
    end

    def find_by(conditions)
      filtered_rows.find { |row| conditions.all? { |key, value| row.fetch(key) == value } }
    end

    def where(conditions = nil)
      return self unless conditions

      Scope.new(@rows, @conditions.merge(conditions))
    end

    def not(conditions)
      obsolete_rows = filtered_rows.reject { |row| conditions.fetch(:chunk_index).include?(row.fetch(:chunk_index)) }
      DeletableScope.new(@rows, obsolete_rows)
    end

    def delete_all
      DeletableScope.new(@rows, filtered_rows).delete_all
    end

    private

    def filtered_rows
      @rows.select { |row| @conditions.all? { |key, value| row.fetch(key) == value } }
    end
  end

  class DeletableScope
    def initialize(all_rows, rows_to_delete)
      @all_rows = all_rows
      @rows_to_delete = rows_to_delete
    end

    def delete_all
      @all_rows.delete_if { |row| @rows_to_delete.include?(row) }
    end
  end
end

RSpec.describe Maglev::Indexer do
  around do |example|
    original = Maglev.configuration
    Maglev.instance_variable_set(:@configuration, Maglev::Configuration.new)
    FakeChunk.reset!
    example.run
  ensure
    Maglev.instance_variable_set(:@configuration, original)
  end

  it "indexes snapshot chunks idempotently by checksum" do
    adapter = FakeEmbeddingAdapter.new(dimensions: 3)
    record = FakeIndexedRecord.new(id: 7, name: "Acme", description: "Support problems")

    2.times do
      described_class.new(record, chunk_model: FakeChunk, embedding_adapter: adapter, embedding_dimensions: 3, chunk_size: 100).index
    end

    expect(FakeChunk.rows.size).to eq(1)
    expect(adapter.calls).to eq(["FakeIndexedRecord#7\nname: Acme\ndescription: Support problems"])
    expect(FakeChunk.rows.first.fetch(:owner)).to be(record)
    expect(FakeChunk.rows.first.fetch(:content_checksum)).to match(/\A[0-9a-f]{64}\z/)
    expect(FakeChunk.rows.first.fetch(:index_version)).to eq(index_version(adapter, dimensions: 3, chunk_size: 100))
  end

  it "re-embeds unchanged built-in content when each index identity component changes" do
    record = FakeIndexedRecord.new(id: 7, name: "Acme", description: "Support problems")

    expect_identity_change(record, :model) { Maglev.configuration.embedding_model = "changed-model" }
    expect_identity_change(record, :dimensions) { |adapter| adapter.instance_variable_set(:@dimensions, 4) }
    expect_identity_change(record, :adapter_version) { |adapter| adapter.maglev_adapter_version = "2" }
    expect_identity_change(record, :chunker_version) { stub_const("Maglev::Chunker::ALGORITHM_VERSION", "2") }
    expect_identity_change(record, :chunk_size, second_chunk_size: 101) {}
    expect_identity_change(record, :application_version) { Maglev.configuration.application_index_version = "2" }
  end

  it "does not reuse a legacy built-in row with a null index version" do
    adapter = FakeEmbeddingAdapter.new(dimensions: 3)
    record = FakeIndexedRecord.new(id: 7, name: "Acme", description: "Support problems")

    described_class.new(record, chunk_model: FakeChunk, embedding_adapter: adapter, embedding_dimensions: 3).index
    FakeChunk.rows.first[:index_version] = nil
    described_class.new(record, chunk_model: FakeChunk, embedding_adapter: adapter, embedding_dimensions: 3).index

    expect(adapter.calls.size).to eq(2)
    expect(FakeChunk.rows.first.fetch(:index_version)).to eq(index_version(adapter, dimensions: 3))
  end

  it "keeps one fingerprint across snapshot retries" do
    adapter = FakeEmbeddingAdapter.new(dimensions: 3)
    record = FakeIndexedRecord.new(id: 7, name: "Acme", description: "Support problems")
    snapshots = ["first", "changed", "changed", "changed"]
    allow(record).to receive(:maglev_snapshot) { snapshots.shift || "changed" }
    identity = instance_double(Maglev::IndexIdentity)
    expect(identity).to receive(:to_s).once.and_return("f" * 64)

    described_class.new(
      record,
      chunk_model: FakeChunk,
      embedding_adapter: adapter,
      embedding_dimensions: 3,
      index_identity: identity
    ).index

    expect(FakeChunk.rows.first.fetch(:index_version)).to eq("f" * 64)
  end

  it "replaces changed content and removes obsolete chunks" do
    adapter = FakeEmbeddingAdapter.new(dimensions: 3)
    record = FakeIndexedRecord.new(id: 7, name: "Acme", description: "one two three four five six seven eight")
    indexer = described_class.new(record, chunk_model: FakeChunk, embedding_adapter: adapter, embedding_dimensions: 3, chunk_size: 60)

    indexer.index
    record.description = "short"
    indexer.index

    expect(FakeChunk.rows.size).to eq(1)
    expect(FakeChunk.rows.first.fetch(:content)).to eq("FakeIndexedRecord#7\nname: Acme\ndescription: short")
  end

  it "raises clearly when an embedding has the wrong dimensions" do
    adapter = FakeEmbeddingAdapter.new(dimensions: 2)
    record = FakeIndexedRecord.new(id: 7, name: "Acme", description: "Support problems")

    expect do
      described_class.new(record, chunk_model: FakeChunk, embedding_adapter: adapter, embedding_dimensions: 3).index
    end.to raise_error(Maglev::ConfigurationError, /expected 3 dimensions/)
  end

  it "unindexes all chunks for a record" do
    adapter = FakeEmbeddingAdapter.new(dimensions: 3)
    record = FakeIndexedRecord.new(id: 7, name: "Acme", description: "Support problems")
    indexer = described_class.new(record, chunk_model: FakeChunk, embedding_adapter: adapter, embedding_dimensions: 3)

    indexer.index
    indexer.unindex

    expect(FakeChunk.rows).to be_empty
  end
  def expect_identity_change(record, _component, second_chunk_size: 100)
    adapter = FakeEmbeddingAdapter.new(dimensions: 3)
    described_class.new(record, chunk_model: FakeChunk, embedding_adapter: adapter, embedding_dimensions: 3, chunk_size: 100).index

    yield adapter
    dimensions = adapter.instance_variable_get(:@dimensions)
    described_class.new(record, chunk_model: FakeChunk, embedding_adapter: adapter, embedding_dimensions: dimensions, chunk_size: second_chunk_size).index

    expect(adapter.calls.size).to eq(2)
    FakeChunk.reset!
    Maglev.instance_variable_set(:@configuration, Maglev::Configuration.new)
  end

  def index_version(adapter, dimensions:, chunk_size: Maglev.configuration.chunk_size)
    configuration = Maglev.configuration
    original_dimensions = configuration.embedding_dimensions
    configuration.embedding_dimensions = dimensions
    Maglev::IndexIdentity.new(
      configuration: configuration,
      adapter: adapter,
      chunk_size: chunk_size
    ).to_s
  ensure
    configuration.embedding_dimensions = original_dimensions
  end
end
