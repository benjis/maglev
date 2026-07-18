# frozen_string_literal: true

require "spec_helper"
require "maglev/retriever"
require "maglev/retrieval_outcome"
require "maglev/search_result"
require "maglev/answerer"

FakeSearchRow = Struct.new(:owner, :content, :source, :distance) unless defined?(FakeSearchRow)

class ThresholdFakeOwner
  def self.name
    "ThresholdFakeOwner"
  end
end

module MaglevRetrievalThresholdSpecs
  ThresholdOwner = Struct.new(:id, :name)

  class ThresholdQueryAdapter
    attr_reader :calls

    def initialize
      @calls = []
    end

    def maglev_adapter_id = "test.threshold"
    def maglev_adapter_version = "1"

    def embed(text)
      @calls << text
      [0.1, 0.2, 0.3]
    end
  end

  class ThresholdChunkModel
    def self.with_rows(rows)
      Class.new do
        define_singleton_method(:rows) { rows }
        define_singleton_method(:candidate_limits) { @candidate_limits ||= [] }

        define_singleton_method(:where) do |conditions|
          ThresholdChunkScope.new(rows, self)
        end
      end
    end
  end

  class ThresholdChunkScope
    def initialize(rows, model)
      @rows = rows
      @model = model
    end

    def where(conditions)
      self
    end

    def nearest_neighbors(_col, _embedding, distance:)
      ThresholdNeighborResult.new(@rows, @model)
    end
  end

  class ThresholdNeighborResult
    include Enumerable

    def initialize(rows, model)
      @rows = rows
      @model = model
    end

    def limit(value)
      @model.candidate_limits << value
      self
    end

    def each(&block)
      @rows.each(&block)
    end
  end

  class ThresholdVectorStore
    attr_reader :search_calls, :search_limits

    def initialize(documents)
      @documents = documents
      @search_calls = []
      @search_limits = []
    end

    def search(vector:, filters:, limit:)
      @search_calls << {vector: vector, filters: filters, limit: limit}
      @search_limits << limit
      @documents.first(limit)
    end
  end
end

class ThresholdAnswerCustomer
  def self.name
    "ThresholdAnswerCustomer"
  end

  attr_reader :id

  def initialize(id)
    @id = id
  end
end

class FakeAnswerRetrieverWithOutcome
  attr_reader :calls

  def initialize(outcome)
    @outcome = outcome
    @calls = []
  end

  def search(query, limit:, owner: nil)
    @calls << {query: query, limit: limit, owner: owner}
    @outcome.results
  end

  def retrieval_outcome(query, limit:, owner: nil, user: nil, minimum_similarity: nil, chunks_per_owner: 1)
    @calls << {query: query, limit: limit, owner: owner}
    @outcome
  end
end

class ThresholdGenerationAdapter
  attr_reader :prompts

  def initialize(text = "Answer grounded in [S1].")
    @text = text
    @prompts = []
  end

  def generate(prompt)
    @prompts << prompt
    @text
  end
end

RSpec.describe "Retrieval threshold and outcome" do
  around do |example|
    original = Maglev.configuration
    configuration = Maglev::Configuration.new
    configuration.embedding_dimensions = 3
    Maglev.instance_variable_set(:@configuration, configuration)
    example.run
  ensure
    Maglev.instance_variable_set(:@configuration, original)
  end

  describe "minimum_similarity configuration" do
    it "defaults to nil (threshold disabled)" do
      expect(Maglev.configuration.minimum_similarity).to be_nil
    end

    it "allows setting a global threshold" do
      Maglev.configuration.minimum_similarity = 0.5
      expect(Maglev.configuration.minimum_similarity).to eq(0.5)
    end
  end

  describe "threshold validation" do
    it "rejects non-numeric thresholds" do
      expect do
        Maglev.configuration.minimum_similarity = "high"
        Maglev::Retriever.new(
          ThresholdFakeOwner,
          chunk_model: MaglevRetrievalThresholdSpecs::ThresholdChunkModel.with_rows([]),
          embedding_adapter: MaglevRetrievalThresholdSpecs::ThresholdQueryAdapter.new
        ).search("test", limit: 5)
      end.to raise_error(ArgumentError, /minimum_similarity/)
    end

    it "rejects thresholds below 0.0" do
      expect do
        Maglev.configuration.minimum_similarity = -0.1
        Maglev::Retriever.new(
          ThresholdFakeOwner,
          chunk_model: MaglevRetrievalThresholdSpecs::ThresholdChunkModel.with_rows([]),
          embedding_adapter: MaglevRetrievalThresholdSpecs::ThresholdQueryAdapter.new
        ).search("test", limit: 5)
      end.to raise_error(ArgumentError, /minimum_similarity/)
    end

    it "rejects thresholds above 1.0" do
      expect do
        Maglev.configuration.minimum_similarity = 1.1
        Maglev::Retriever.new(
          ThresholdFakeOwner,
          chunk_model: MaglevRetrievalThresholdSpecs::ThresholdChunkModel.with_rows([]),
          embedding_adapter: MaglevRetrievalThresholdSpecs::ThresholdQueryAdapter.new
        ).search("test", limit: 5)
      end.to raise_error(ArgumentError, /minimum_similarity/)
    end

    it "rejects Infinity as threshold" do
      expect do
        Maglev.configuration.minimum_similarity = Float::INFINITY
        Maglev::Retriever.new(
          ThresholdFakeOwner,
          chunk_model: MaglevRetrievalThresholdSpecs::ThresholdChunkModel.with_rows([]),
          embedding_adapter: MaglevRetrievalThresholdSpecs::ThresholdQueryAdapter.new
        ).search("test", limit: 5)
      end.to raise_error(ArgumentError, /minimum_similarity/)
    end

    it "rejects NaN as threshold" do
      expect do
        Maglev.configuration.minimum_similarity = Float::NAN
        Maglev::Retriever.new(
          ThresholdFakeOwner,
          chunk_model: MaglevRetrievalThresholdSpecs::ThresholdChunkModel.with_rows([]),
          embedding_adapter: MaglevRetrievalThresholdSpecs::ThresholdQueryAdapter.new
        ).search("test", limit: 5)
      end.to raise_error(ArgumentError, /minimum_similarity/)
    end

    it "accepts threshold of 0.0" do
      Maglev.configuration.minimum_similarity = 0.0
      expect do
        Maglev::Retriever.new(
          ThresholdFakeOwner,
          chunk_model: MaglevRetrievalThresholdSpecs::ThresholdChunkModel.with_rows([]),
          embedding_adapter: MaglevRetrievalThresholdSpecs::ThresholdQueryAdapter.new
        ).search("test", limit: 5)
      end.not_to raise_error
    end

    it "accepts threshold of 1.0" do
      Maglev.configuration.minimum_similarity = 1.0
      expect do
        Maglev::Retriever.new(
          ThresholdFakeOwner,
          chunk_model: MaglevRetrievalThresholdSpecs::ThresholdChunkModel.with_rows([]),
          embedding_adapter: MaglevRetrievalThresholdSpecs::ThresholdQueryAdapter.new
        ).search("test", limit: 5)
      end.not_to raise_error
    end
  end

  describe "threshold filtering" do
    it "filters results below the global threshold" do
      Maglev.configuration.minimum_similarity = 0.7
      rows = [
        FakeSearchRow.new(MaglevRetrievalThresholdSpecs::ThresholdOwner.new(1, "Acme"), "high match", "snapshot", 0.1),   # similarity 0.9
        FakeSearchRow.new(MaglevRetrievalThresholdSpecs::ThresholdOwner.new(2, "Beta"), "low match", "snapshot", 0.5),   # similarity 0.5
        FakeSearchRow.new(MaglevRetrievalThresholdSpecs::ThresholdOwner.new(3, "Gamma"), "mid match", "snapshot", 0.3)    # similarity 0.7 (boundary)
      ]
      chunk_model = MaglevRetrievalThresholdSpecs::ThresholdChunkModel.with_rows(rows)

      results = Maglev::Retriever.new(
        ThresholdFakeOwner,
        chunk_model: chunk_model,
        embedding_adapter: MaglevRetrievalThresholdSpecs::ThresholdQueryAdapter.new
      ).search("test", limit: 10)

      expect(results.map(&:content)).to eq(["high match", "mid match"])
    end

    it "accepts results exactly at the threshold (inclusive boundary)" do
      Maglev.configuration.minimum_similarity = 0.7
      rows = [
        FakeSearchRow.new(MaglevRetrievalThresholdSpecs::ThresholdOwner.new(1, "Acme"), "exact match", "snapshot", 0.3)  # similarity 0.7
      ]
      chunk_model = MaglevRetrievalThresholdSpecs::ThresholdChunkModel.with_rows(rows)

      results = Maglev::Retriever.new(
        ThresholdFakeOwner,
        chunk_model: chunk_model,
        embedding_adapter: MaglevRetrievalThresholdSpecs::ThresholdQueryAdapter.new
      ).search("test", limit: 10)

      expect(results.map(&:content)).to eq(["exact match"])
    end

    it "allows per-request override of the global threshold" do
      Maglev.configuration.minimum_similarity = 0.3
      rows = [
        FakeSearchRow.new(MaglevRetrievalThresholdSpecs::ThresholdOwner.new(1, "Acme"), "high", "snapshot", 0.1),    # similarity 0.9
        FakeSearchRow.new(MaglevRetrievalThresholdSpecs::ThresholdOwner.new(2, "Beta"), "low", "snapshot", 0.85)     # similarity 0.15
      ]
      chunk_model = MaglevRetrievalThresholdSpecs::ThresholdChunkModel.with_rows(rows)

      results = Maglev::Retriever.new(
        ThresholdFakeOwner,
        chunk_model: chunk_model,
        embedding_adapter: MaglevRetrievalThresholdSpecs::ThresholdQueryAdapter.new
      ).search("test", limit: 10, minimum_similarity: 0.5)

      expect(results.map(&:content)).to eq(%w[high])
    end

    it "returns empty when all results are below threshold" do
      Maglev.configuration.minimum_similarity = 0.95
      rows = [
        FakeSearchRow.new(MaglevRetrievalThresholdSpecs::ThresholdOwner.new(1, "Acme"), "low", "snapshot", 0.5)  # similarity 0.5
      ]
      chunk_model = MaglevRetrievalThresholdSpecs::ThresholdChunkModel.with_rows(rows)

      results = Maglev::Retriever.new(
        ThresholdFakeOwner,
        chunk_model: chunk_model,
        embedding_adapter: MaglevRetrievalThresholdSpecs::ThresholdQueryAdapter.new
      ).search("test", limit: 10)

      expect(results).to be_empty
    end

    it "returns all results when threshold is nil (disabled)" do
      Maglev.configuration.minimum_similarity = nil
      rows = [
        FakeSearchRow.new(MaglevRetrievalThresholdSpecs::ThresholdOwner.new(1, "Acme"), "any", "snapshot", 0.9)
      ]
      chunk_model = MaglevRetrievalThresholdSpecs::ThresholdChunkModel.with_rows(rows)

      results = Maglev::Retriever.new(
        ThresholdFakeOwner,
        chunk_model: chunk_model,
        embedding_adapter: MaglevRetrievalThresholdSpecs::ThresholdQueryAdapter.new
      ).search("test", limit: 10)

      expect(results.map(&:content)).to eq(%w[any])
    end
  end

  describe "custom store threshold filtering" do
    it "filters custom store results below the threshold" do
      Maglev.configuration.minimum_similarity = 0.7
      documents = [
        FakeSearchRow.new(MaglevRetrievalThresholdSpecs::ThresholdOwner.new(1, "Acme"), "high", "snapshot", 0.1),   # similarity 0.9
        FakeSearchRow.new(MaglevRetrievalThresholdSpecs::ThresholdOwner.new(2, "Beta"), "low", "snapshot", 0.5)    # similarity 0.5
      ]
      store = MaglevRetrievalThresholdSpecs::ThresholdVectorStore.new(documents)

      results = Maglev::Retriever.new(
        ThresholdFakeOwner,
        vector_store: store,
        embedding_adapter: MaglevRetrievalThresholdSpecs::ThresholdQueryAdapter.new
      ).search("test", limit: 10)

      expect(results.map(&:content)).to eq(%w[high])
    end

    it "accepts custom store results exactly at the threshold" do
      Maglev.configuration.minimum_similarity = 0.7
      documents = [
        FakeSearchRow.new(MaglevRetrievalThresholdSpecs::ThresholdOwner.new(1, "Acme"), "exact", "snapshot", 0.3)   # similarity 0.7
      ]
      store = MaglevRetrievalThresholdSpecs::ThresholdVectorStore.new(documents)

      results = Maglev::Retriever.new(
        ThresholdFakeOwner,
        vector_store: store,
        embedding_adapter: MaglevRetrievalThresholdSpecs::ThresholdQueryAdapter.new
      ).search("test", limit: 10)

      expect(results.map(&:content)).to eq(%w[exact])
    end
  end

  describe "retrieval outcome" do
    it "returns an immutable outcome with accepted results and metadata" do
      Maglev.configuration.minimum_similarity = 0.5
      owner = MaglevRetrievalThresholdSpecs::ThresholdOwner.new(1, "Acme")
      rows = [
        FakeSearchRow.new(owner, "match", "snapshot", 0.2)
      ]
      chunk_model = MaglevRetrievalThresholdSpecs::ThresholdChunkModel.with_rows(rows)
      retriever = Maglev::Retriever.new(
        ThresholdFakeOwner,
        chunk_model: chunk_model,
        embedding_adapter: MaglevRetrievalThresholdSpecs::ThresholdQueryAdapter.new
      )

      outcome = retriever.retrieval_outcome("test", limit: 10)

      expect(outcome).to be_a(Maglev::RetrievalOutcome)
      expect(outcome.results.size).to eq(1)
      expect(outcome.minimum_similarity).to eq(0.5)
      expect(outcome.examined_count).to eq(1)
      expect(outcome.accepted_count).to eq(1)
      expect(outcome.rejected_count).to eq(0)
      expect(outcome.best_similarity).to eq(0.8)
      expect(outcome).to be_frozen
    end

    it "tracks rejected results and reports best_similarity when all rejected" do
      Maglev.configuration.minimum_similarity = 0.95
      owner = MaglevRetrievalThresholdSpecs::ThresholdOwner.new(1, "Acme")
      rows = [
        FakeSearchRow.new(owner, "low", "snapshot", 0.5)
      ]
      chunk_model = MaglevRetrievalThresholdSpecs::ThresholdChunkModel.with_rows(rows)
      retriever = Maglev::Retriever.new(
        ThresholdFakeOwner,
        chunk_model: chunk_model,
        embedding_adapter: MaglevRetrievalThresholdSpecs::ThresholdQueryAdapter.new
      )

      outcome = retriever.retrieval_outcome("test", limit: 10)

      expect(outcome.results).to be_empty
      expect(outcome.examined_count).to eq(1)
      expect(outcome.accepted_count).to eq(0)
      expect(outcome.rejected_count).to eq(1)
      expect(outcome.best_similarity).to eq(0.5)
    end

    it "returns nil best_similarity when all distances are nil" do
      Maglev.configuration.minimum_similarity = nil
      owner = MaglevRetrievalThresholdSpecs::ThresholdOwner.new(1, "Acme")
      rows = [
        FakeSearchRow.new(owner, "unknown", "snapshot", nil)
      ]
      chunk_model = MaglevRetrievalThresholdSpecs::ThresholdChunkModel.with_rows(rows)
      retriever = Maglev::Retriever.new(
        ThresholdFakeOwner,
        chunk_model: chunk_model,
        embedding_adapter: MaglevRetrievalThresholdSpecs::ThresholdQueryAdapter.new
      )

      outcome = retriever.retrieval_outcome("test", limit: 10)

      expect(outcome.best_similarity).to be_nil
    end
  end

  describe "answerer insufficient context with rejection metadata" do
    it "returns insufficient context with rejection metadata when all candidates rejected" do
      Maglev.configuration.minimum_similarity = 0.95

      retriever = FakeAnswerRetrieverWithOutcome.new(
        Maglev::RetrievalOutcome.new(
          results: [],
          minimum_similarity: 0.95,
          examined_count: 3,
          accepted_count: 0,
          rejected_count: 3,
          best_similarity: 0.4
        )
      )
      generator = ThresholdGenerationAdapter.new

      response = Maglev::Answerer.new(ThresholdAnswerCustomer, retriever: retriever, generation_adapter: generator)
        .ask("What changed?", limit: 5)

      expect(response.text).to eq("Insufficient context to answer the question.")
      expect(response.metadata[:reason]).to eq("insufficient_context")
      expect(response.metadata[:minimum_similarity]).to eq(0.95)
      expect(response.metadata[:examined_count]).to eq(3)
      expect(response.metadata[:accepted_count]).to eq(0)
      expect(response.metadata[:rejected_count]).to eq(3)
      expect(response.metadata[:best_similarity]).to eq(0.4)
      expect(generator.prompts).to be_empty
    end
  end
end
