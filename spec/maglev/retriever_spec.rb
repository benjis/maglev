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

class BoundedAuthorizedScope
  def initialize(ids) = @ids = ids
  def limit(value) = self.class.new(@ids.first(value))
  def pluck(column) = (column == :id) ? @ids : raise("unexpected column")
end

class PushdownAuthorization
  def initialize(ids) = @ids = ids
  def scope(model:, user:) = BoundedAuthorizedScope.new(@ids)
  def authorize(record:, user:) = @ids.include?(record.id)
end

class MaliciousV2Store < DuplicateOwnerVectorStore
  def contract_version = 2
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
    expect(chunk_model.candidate_limits).to eq([8])
  end

  it "rejects invalid limits and caps adversarial candidate requests" do
    chunk_model = FakeSearchChunk.with_rows([])
    retriever = described_class.new(FakeSearchOwner, chunk_model: chunk_model,
      embedding_adapter: FakeQueryEmbeddingAdapter.new)
    expect { retriever.search("q", limit: 0) }.to raise_error(ArgumentError, /limit must be a positive Integer/)

    original = Maglev.configuration.retrieval_max_candidates
    Maglev.configuration.retrieval_max_candidates = 20
    retriever.search("q", limit: 1_000_000)
    expect(chunk_model.candidate_limits.last).to eq(20)
  ensure
    Maglev.configuration.retrieval_max_candidates = original
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

    expect(store.limits).to eq([8])
    expect(store.filters.first.to_h).to include(index_version: current_index_version(FakeQueryEmbeddingAdapter.new))
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

  it "normalizes similarity to 1.0 - distance clamped to 0.0..1.0" do
    result_near = Maglev::SearchResult.new(owner: "o", content: "c", source: "s", distance: 0.05)
    expect(result_near.similarity).to eq(0.95)

    result_zero = Maglev::SearchResult.new(owner: "o", content: "c", source: "s", distance: 0.0)
    expect(result_zero.similarity).to eq(1.0)

    result_far = Maglev::SearchResult.new(owner: "o", content: "c", source: "s", distance: 1.5)
    expect(result_far.similarity).to eq(0.0)
  end

  it "returns nil similarity for nil distance" do
    result = Maglev::SearchResult.new(owner: "o", content: "c", source: "s", distance: nil)
    expect(result.similarity).to be_nil
  end

  it "rejects results below minimum_similarity threshold" do
    adapter = FakeQueryEmbeddingAdapter.new
    chunk_model = FakeSearchChunk.with_rows([
      FakeSearchRow.new("customer-1", "first", "snapshot", 0.1),
      FakeSearchRow.new("customer-2", "second", "snapshot", 0.8)
    ])

    results = described_class.new(FakeSearchOwner, chunk_model: chunk_model, embedding_adapter: adapter)
      .search("support", limit: 10, minimum_similarity: 0.7)

    expect(results.map(&:owner)).to eq(["customer-1"])
    expect(results.map(&:content)).to eq(%w[first])
  end

  it "accepts results at the exact threshold boundary (inclusive)" do
    adapter = FakeQueryEmbeddingAdapter.new
    chunk_model = FakeSearchChunk.with_rows([
      FakeSearchRow.new("customer-1", "first", "snapshot", 0.3),
      FakeSearchRow.new("customer-2", "second", "snapshot", 0.3)
    ])

    results = described_class.new(FakeSearchOwner, chunk_model: chunk_model, embedding_adapter: adapter)
      .search("support", limit: 10, minimum_similarity: 0.7)

    expect(results.map(&:owner)).to eq(["customer-1", "customer-2"])
  end

  it "validates minimum_similarity as a finite Numeric in 0.0..1.0" do
    chunk_model = FakeSearchChunk.with_rows([])

    expect do
      described_class.new(FakeSearchOwner, chunk_model: chunk_model, embedding_adapter: FakeQueryEmbeddingAdapter.new)
        .search("test", limit: 10, minimum_similarity: -0.1)
    end.to raise_error(ArgumentError, /minimum_similarity/)

    expect do
      described_class.new(FakeSearchOwner, chunk_model: chunk_model, embedding_adapter: FakeQueryEmbeddingAdapter.new)
        .search("test", limit: 10, minimum_similarity: 1.1)
    end.to raise_error(ArgumentError, /minimum_similarity/)

    expect do
      described_class.new(FakeSearchOwner, chunk_model: chunk_model, embedding_adapter: FakeQueryEmbeddingAdapter.new)
        .search("test", limit: 10, minimum_similarity: "bad")
    end.to raise_error(ArgumentError, /minimum_similarity/)
  end

  it "returns a retrieval outcome with bounded counts via retrieval_outcome" do
    adapter = FakeQueryEmbeddingAdapter.new
    chunk_model = FakeSearchChunk.with_rows([
      FakeSearchRow.new("customer-1", "first", "snapshot", 0.1),
      FakeSearchRow.new("customer-2", "second", "snapshot", 0.2),
      FakeSearchRow.new("customer-3", "third", "snapshot", 0.8)
    ])

    outcome = described_class.new(FakeSearchOwner, chunk_model: chunk_model, embedding_adapter: adapter)
      .retrieval_outcome("support", limit: 10, minimum_similarity: 0.7)

    expect(outcome).to be_a(Maglev::RetrievalOutcome)
    expect(outcome.results.size).to eq(2)
    expect(outcome.accepted_count).to eq(2)
    expect(outcome.rejected_count).to eq(1)
    expect(outcome.minimum_similarity).to eq(0.7)
    expect(outcome.best_similarity).to eq(0.9)
  end

  it "returns inspectable evidence with a trace id and context budget decisions" do
    chunk_model = FakeSearchChunk.with_rows([
      FakeSearchRow.new("customer-1", "selected", "attribute:name", 0.1),
      FakeSearchRow.new("customer-2", "rejected", "attribute:name", 0.8)
    ])

    result = described_class.new(FakeSearchOwner, chunk_model: chunk_model, embedding_adapter: FakeQueryEmbeddingAdapter.new)
      .retrieve("support", limit: 2, minimum_similarity: 0.5)

    expect(result.query).to eq("support")
    expect(result.considered.map(&:content)).to eq(%w[selected rejected])
    expect(result.selected.map(&:content)).to eq(["selected"])
    expect(result.rejected.map { |item| item.fetch(:reason) }).to eq([:relevance_threshold])
    expect(result.trace_id).to match(/\A[0-9a-f-]{36}\z/)
    expect(result.timings).to include(:embedding_ms, :retrieval_ms, :context_assembly_ms, :total_ms)
  end

  it "retains bounded multiple chunks for model-level answering" do
    adapter = FakeQueryEmbeddingAdapter.new
    chunk_model = FakeSearchChunk.with_rows([
      FakeSearchRow.new("customer-1", "first", "snapshot", 0.1),
      FakeSearchRow.new("customer-1", "second", "snapshot", 0.2),
      FakeSearchRow.new("customer-2", "third", "snapshot", 0.3)
    ])

    outcome = described_class.new(FakeSearchOwner, chunk_model: chunk_model, embedding_adapter: adapter)
      .retrieval_outcome("support", limit: 2, chunks_per_owner: 2)

    expect(outcome.results.map(&:content)).to eq(%w[first second third])
    expect(chunk_model.candidate_limits).to eq([16])
  end

  it "validates the threshold before embedding" do
    adapter = FakeQueryEmbeddingAdapter.new

    expect do
      described_class.new(FakeSearchOwner, chunk_model: FakeSearchChunk.with_rows([]), embedding_adapter: adapter)
        .search("support", limit: 2, minimum_similarity: 2)
    end.to raise_error(ArgumentError, /minimum_similarity/)

    expect(adapter.calls).to be_empty
  end

  it "applies global minimum_similarity from configuration when request override is nil" do
    Maglev.configuration.minimum_similarity = 0.6
    adapter = FakeQueryEmbeddingAdapter.new
    chunk_model = FakeSearchChunk.with_rows([
      FakeSearchRow.new("customer-1", "first", "snapshot", 0.5),
      FakeSearchRow.new("customer-2", "second", "snapshot", 0.3)
    ])

    results = described_class.new(FakeSearchOwner, chunk_model: chunk_model, embedding_adapter: adapter)
      .search("support", limit: 10)

    expect(results.map(&:owner)).to eq(["customer-2"])

    Maglev.configuration.minimum_similarity = nil
  end

  it "overrides global minimum_similarity when request specifies a value" do
    Maglev.configuration.minimum_similarity = 0.3
    adapter = FakeQueryEmbeddingAdapter.new
    chunk_model = FakeSearchChunk.with_rows([
      FakeSearchRow.new("customer-1", "first", "snapshot", 0.5),
      FakeSearchRow.new("customer-2", "second", "snapshot", 0.7)
    ])

    results = described_class.new(FakeSearchOwner, chunk_model: chunk_model, embedding_adapter: adapter)
      .search("support", limit: 10, minimum_similarity: 0.8)

    expect(results).to be_empty

    Maglev.configuration.minimum_similarity = nil
  end

  it "returns empty outcome with metadata when all candidates rejected" do
    adapter = FakeQueryEmbeddingAdapter.new
    chunk_model = FakeSearchChunk.with_rows([
      FakeSearchRow.new("customer-1", "first", "snapshot", 0.5),
      FakeSearchRow.new("customer-2", "second", "snapshot", 0.7)
    ])

    outcome = described_class.new(FakeSearchOwner, chunk_model: chunk_model, embedding_adapter: adapter)
      .retrieval_outcome("support", limit: 10, minimum_similarity: 0.9)

    expect(outcome.results).to be_empty
    expect(outcome.examined_count).to eq(2)
    expect(outcome.rejected_count).to eq(2)
    expect(outcome.empty_reason).to eq(:threshold_rejected)
    expect(outcome.best_similarity).to eq(0.5)
  end

  it "rejects results with nil distance when threshold is enabled" do
    adapter = FakeQueryEmbeddingAdapter.new
    chunk_model = FakeSearchChunk.with_rows([
      FakeSearchRow.new("customer-1", "first", "snapshot", nil),
      FakeSearchRow.new("customer-2", "second", "snapshot", 0.3)
    ])

    results = described_class.new(FakeSearchOwner, chunk_model: chunk_model, embedding_adapter: adapter)
      .search("support", limit: 10, minimum_similarity: 0.5)

    expect(results.map(&:owner)).to eq(["customer-2"])
  end

  it "applies threshold on custom vector store path" do
    documents = [
      FakeSearchRow.new("customer-1", "first", "snapshot", 0.1),
      FakeSearchRow.new("customer-2", "second", "snapshot", 0.8)
    ]
    store = DuplicateOwnerVectorStore.new(documents)

    results = described_class.new(
      FakeSearchOwner,
      vector_store: store,
      embedding_adapter: FakeQueryEmbeddingAdapter.new
    ).search("support", limit: 10, minimum_similarity: 0.7)

    expect(results.map(&:owner)).to eq(["customer-1"])
  end

  it "removes unauthorized custom-store results before returning them" do
    allowed = Struct.new(:id).new(1)
    denied = Struct.new(:id).new(2)
    store = DuplicateOwnerVectorStore.new([
      FakeSearchRow.new(allowed, "public", "snapshot", 0.1),
      FakeSearchRow.new(denied, "secret", "snapshot", 0.2)
    ])
    adapter = Class.new do
      def scope(model:, user:) = model.all

      def authorize(record:, user:)
        user.include?(record.id)
      end
    end.new

    outcome = described_class.new(
      FakeSearchOwner,
      vector_store: store,
      embedding_adapter: FakeQueryEmbeddingAdapter.new,
      authorization: Maglev::Authorization.new(adapter: adapter)
    ).retrieval_outcome("support", limit: 2, user: [1])

    expect(outcome.results.map(&:content)).to eq(["public"])
    expect(outcome.examined_count).to eq(1)
  end

  it "pushes bounded authorization owner ids and the resolved tenant into custom-store filters" do
    allowed = Struct.new(:id).new(1)
    store = DuplicateOwnerVectorStore.new([FakeSearchRow.new(allowed, "public", "snapshot", 0.1)])
    Maglev.configuration.tenant_id_resolver = ->(record: nil, user: nil) { record&.tenant_id || user&.fetch(:tenant_id) }
    authorization = Maglev::Authorization.new(adapter: PushdownAuthorization.new([1]))

    described_class.new(FakeSearchOwner, vector_store: store, embedding_adapter: FakeQueryEmbeddingAdapter.new,
      authorization: authorization).retrieve("support", limit: 2, user: {tenant_id: "tenant-7"})

    expect(store.filters.first.to_h).to include(owner_ids: [1], tenant_id: "tenant-7")
  end

  it "explains no documents and authorization filtering separately" do
    empty = described_class.new(FakeSearchOwner, chunk_model: FakeSearchChunk.with_rows([]), embedding_adapter: FakeQueryEmbeddingAdapter.new)
      .retrieve("support", limit: 2)
    expect(empty.reasons).to eq([:no_documents])

    denied = Struct.new(:id).new(2)
    store = DuplicateOwnerVectorStore.new([FakeSearchRow.new(denied, "secret", "snapshot", 0.1)])
    authorization = Maglev::Authorization.new(adapter: PushdownAuthorization.new([1]))
    filtered = described_class.new(FakeSearchOwner, vector_store: store, embedding_adapter: FakeQueryEmbeddingAdapter.new,
      authorization: authorization).retrieve("support", limit: 2, user: :user)
    expect(filtered.reasons).to include(:authorization_filtered)
  end

  it "does not leak an empty authorization scope across reused retrievals" do
    allowed = Struct.new(:id).new(1)
    store = DuplicateOwnerVectorStore.new([FakeSearchRow.new(allowed, "public", "snapshot", 0.1)])
    adapter = PushdownAuthorization.new([])
    retriever = described_class.new(FakeSearchOwner, vector_store: store, embedding_adapter: FakeQueryEmbeddingAdapter.new,
      authorization: Maglev::Authorization.new(adapter: adapter))

    expect(retriever.retrieve("first", limit: 1, user: :denied).selected).to be_empty
    adapter.instance_variable_set(:@ids, [1])
    expect(retriever.retrieve("second", limit: 1, user: :allowed).selected.map(&:content)).to eq(["public"])
  end

  it "rejects forged owners and tenant metadata after custom-store hydration" do
    forged = Struct.new(:id).new(99)
    document = Maglev::VectorStores::Document.new(owner_type: "FakeSearchOwner", owner_id: 1,
      owner_model_name: "FakeSearchOwner", owner: forged, source: "snapshot", chunk_index: 0,
      content: "secret", content_checksum: "x", embedding_model: "fake", index_version: "a" * 64,
      embedding: [0.1, 0.2, 0.3], tenant_id: "other", distance: 0.1)
    store = MaliciousV2Store.new([document])
    Maglev.configuration.tenant_id_resolver = ->(record: nil, user: nil) { "expected" }

    result = described_class.new(FakeSearchOwner, vector_store: store, embedding_adapter: FakeQueryEmbeddingAdapter.new)
      .retrieve("support", limit: 1, user: :user)

    expect(result.selected).to be_empty
  end

  it "fills selected owners from accepted custom-store candidates after threshold rejection" do
    store = DuplicateOwnerVectorStore.new([
      FakeSearchRow.new("rejected-owner", "too far", "snapshot", 0.8),
      FakeSearchRow.new("accepted-owner", "close enough", "snapshot", 0.1)
    ])

    outcome = described_class.new(
      FakeSearchOwner,
      vector_store: store,
      embedding_adapter: FakeQueryEmbeddingAdapter.new
    ).retrieval_outcome("support", limit: 1, minimum_similarity: 0.5)

    expect(store.limits).to eq([4])
    expect(outcome.results.map(&:owner)).to eq(["accepted-owner"])
    expect(outcome).to have_attributes(examined_count: 2, accepted_count: 1, rejected_count: 1)
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
