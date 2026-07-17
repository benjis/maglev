# frozen_string_literal: true

require "spec_helper"
require "maglev/indexer"
require "maglev/retriever"

class FakeSearchOwner
  def self.name
    "FakeSearchOwner"
  end

  def self.all
    FakeAuthorizedScope.new
  end
end

class FakeAuthorizedScope
  def select(column)
    raise "unexpected column" unless column == :id

    "authorized-owner-ids"
  end
end

class FakeRetrieverAuthorization
  def configured?
    true
  end

  def scope(model:, user:)
    raise "unexpected model" unless model == FakeSearchOwner
    raise "unexpected user" unless user == :current_user

    model.all
  end
end

class FakeQueryEmbeddingAdapter
  attr_reader :calls

  def initialize
    @calls = []
  end

  def maglev_adapter_id = "test.query_embedding"

  def maglev_adapter_version = "1"

  def embed(text)
    @calls << text
    [0.1, 0.2, 0.3]
  end
end

class FakeSearchChunk
  def self.with_rows(rows)
    Class.new do
      define_singleton_method(:conditions) do
        @conditions ||= []
      end

      define_singleton_method(:candidate_limits) do
        @candidate_limits ||= []
      end

      define_singleton_method(:where) do |conditions|
        self.conditions << conditions
        FakeSearchChunk::Scope.new(rows, self)
      end
    end
  end

  class Scope
    def initialize(rows, chunk_model)
      @rows = rows
      @chunk_model = chunk_model
    end

    def where(conditions)
      @chunk_model.conditions << conditions
      self
    end

    def nearest_neighbors(_column, _embedding, distance:)
      raise "unexpected distance" unless distance == "cosine"

      LimitedRows.new(@rows, @chunk_model)
    end

    class LimitedRows
      include Enumerable

      attr_reader :requested_limit

      def initialize(rows, chunk_model)
        @rows = rows
        @chunk_model = chunk_model
      end

      def limit(value)
        @requested_limit = value
        @chunk_model.candidate_limits << value
        self
      end

      def each(&block)
        raise "rows were enumerated without a database limit" unless @requested_limit

        @rows.first(@requested_limit).each(&block)
      end
    end
  end
end

FakeSearchRow = Struct.new(:owner, :content, :source, :distance)

class DuplicateOwnerVectorStore
  attr_reader :filters, :limits

  def initialize(documents)
    @documents = documents
    @filters = []
    @limits = []
  end

  def search(vector:, filters:, limit:)
    @filters << filters
    @limits << limit
    @documents.first(limit)
  end
end

class IdentityCaptureVectorStore
  attr_reader :documents, :filters

  def initialize
    @documents = []
    @filters = []
  end

  def fetch(ids:) = []

  def replace_owner(owner_type:, owner_id:, documents:)
    @documents = documents
  end

  def search(vector:, filters:, limit:)
    @filters << filters
    @documents.first(limit)
  end
end

class IdentitySearchRecord
  attr_reader :id

  def self.name = "IdentitySearchRecord"

  def initialize(id)
    @id = id
  end

  def maglev_snapshot = "identity content"
end

RSpec.describe Maglev::Retriever do
  around do |example|
    original = Maglev.configuration
    configuration = Maglev::Configuration.new
    configuration.embedding_dimensions = 3
    Maglev.instance_variable_set(:@configuration, configuration)
    example.run
  ensure
    Maglev.instance_variable_set(:@configuration, original)
  end

  it "returns typed results capped to one chunk per owner" do
    adapter = FakeQueryEmbeddingAdapter.new
    chunk_model = FakeSearchChunk.with_rows([
      FakeSearchRow.new("customer-1", "first", "snapshot", 0.1),
      FakeSearchRow.new("customer-1", "duplicate", "snapshot", 0.2),
      FakeSearchRow.new("customer-2", "second", "snapshot", 0.3)
    ])

    results = described_class.new(FakeSearchOwner, chunk_model: chunk_model, embedding_adapter: adapter).search("support", limit: 2)

    expect(adapter.calls).to eq(["support"])
    expect(chunk_model.conditions).to eq([{owner_model_name: "FakeSearchOwner", index_version: current_index_version(adapter)}])
    expect(results.map(&:owner)).to eq(["customer-1", "customer-2"])
    expect(results.map(&:content)).to eq(%w[first second])
    expect(results.first.similarity).to eq(0.9)
  end

  it "can scope retrieval to a single owner" do
    owner = "customer-1"
    chunk_model = FakeSearchChunk.with_rows([
      FakeSearchRow.new(owner, "first", "snapshot", 0.1),
      FakeSearchRow.new(owner, "second", "snapshot", 0.2)
    ])

    results = described_class.new(FakeSearchOwner, chunk_model: chunk_model, embedding_adapter: FakeQueryEmbeddingAdapter.new)
      .search("support", limit: 2, owner: owner)

    expect(chunk_model.conditions).to eq([
      {owner_model_name: "FakeSearchOwner", index_version: current_index_version(FakeQueryEmbeddingAdapter.new)},
      {owner: owner}
    ])
    expect(results.map(&:content)).to eq(%w[first second])
  end

  it "applies a bounded candidate limit before enumerating ActiveRecord results" do
    chunk_model = FakeSearchChunk.with_rows([
      FakeSearchRow.new("customer-1", "first", "snapshot", 0.1),
      FakeSearchRow.new("customer-1", "duplicate", "snapshot", 0.2),
      FakeSearchRow.new("customer-2", "second", "snapshot", 0.3)
    ])

    results = described_class.new(FakeSearchOwner, chunk_model: chunk_model, embedding_adapter: FakeQueryEmbeddingAdapter.new)
      .search("support", limit: 2)

    expect(results.map(&:owner)).to eq(["customer-1", "customer-2"])
    expect(chunk_model.candidate_limits).to eq([4])
  end

  it "boundedly over-fetches custom-store candidates before owner de-duplication" do
    documents = [
      FakeSearchRow.new("customer-1", "first", "snapshot", 0.1),
      FakeSearchRow.new("customer-1", "duplicate", "snapshot", 0.2),
      FakeSearchRow.new("customer-2", "second", "snapshot", 0.3),
      FakeSearchRow.new("customer-3", "third", "snapshot", 0.4)
    ]
    store = DuplicateOwnerVectorStore.new(documents)

    results = described_class.new(
      FakeSearchOwner,
      vector_store: store,
      embedding_adapter: FakeQueryEmbeddingAdapter.new
    ).search("support", limit: 2)

    expect(store.limits).to eq([4])
    expect(store.filters.first).to include(index_version: current_index_version(FakeQueryEmbeddingAdapter.new))
    expect(results.map(&:owner)).to eq(["customer-1", "customer-2"])
  end

  it "passes the exact Indexer-written fingerprint to a custom store" do
    store = IdentityCaptureVectorStore.new
    adapter = FakeQueryEmbeddingAdapter.new
    record = IdentitySearchRecord.new(7)
    Maglev.configuration.embedding_dimensions = 1536
    Maglev.configuration.chunk_size = 999
    Maglev::Indexer.new(
      record,
      vector_store: store,
      embedding_adapter: adapter,
      embedding_dimensions: 3,
      chunk_size: 100
    ).index
    written_version = store.documents.first.index_version

    described_class.new(
      IdentitySearchRecord,
      vector_store: store,
      embedding_adapter: adapter,
      embedding_dimensions: 3,
      chunk_size: 100
    )
      .search("identity", limit: 1)

    expect(store.filters.last.fetch(:index_version)).to eq(written_version)
  end

  it "validates query embeddings against the effective dimensions" do
    Maglev.configuration.embedding_dimensions = 1536

    expect do
      described_class.new(
        FakeSearchOwner,
        chunk_model: FakeSearchChunk.with_rows([]),
        embedding_adapter: FakeQueryEmbeddingAdapter.new,
        embedding_dimensions: 2
      ).search("identity", limit: 1)
    end.to raise_error(Maglev::ConfigurationError, /expected 2 dimensions/)
  end

  it "pre-scopes class retrieval through configured authorization" do
    chunk_model = FakeSearchChunk.with_rows([])

    described_class.new(
      FakeSearchOwner,
      chunk_model: chunk_model,
      embedding_adapter: FakeQueryEmbeddingAdapter.new,
      authorization: FakeRetrieverAuthorization.new
    ).search("support", limit: 2, user: :current_user)

    expect(chunk_model.conditions).to eq([
      {owner_model_name: "FakeSearchOwner", index_version: current_index_version(FakeQueryEmbeddingAdapter.new)},
      {owner_id: "authorized-owner-ids"}
    ])
  end

  def current_index_version(adapter)
    Maglev::IndexIdentity.new(
      configuration: Maglev.configuration,
      adapter: adapter,
      chunk_size: Maglev.configuration.chunk_size
    ).to_s
  end
end
