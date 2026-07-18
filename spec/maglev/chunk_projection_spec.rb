# frozen_string_literal: true

require "spec_helper"
require "maglev/answerer"
require "maglev/retrieval_outcome"
require "maglev/search_result"

class ChunkProjectionCustomer
  def self.name
    "ChunkProjectionCustomer"
  end

  attr_reader :id

  def initialize(id)
    @id = id
  end
end

class FakeChunkProjectionRetriever
  attr_reader :calls

  def initialize(outcome)
    @outcome = outcome
    @calls = []
  end

  def search(query, limit:, owner: nil, user: nil, minimum_similarity: nil)
    @calls << {query: query, limit: limit, owner: owner}
    @outcome.results
  end

  def retrieval_outcome(query, limit:, owner: nil, user: nil, minimum_similarity: nil, chunks_per_owner: 1)
    @calls << {query: query, limit: limit, owner: owner, minimum_similarity: minimum_similarity, chunks_per_owner: chunks_per_owner}
    results = if owner
      @outcome.results
    else
      @outcome.results
        .group_by { |result| [result.owner.class.name, result.owner.id] }
        .sort_by { |_key, chunks| chunks.map(&:distance).min }
        .first(limit)
        .flat_map { |_key, chunks| chunks.sort_by(&:distance).first(chunks_per_owner) }
        .sort_by(&:distance)
    end
    Maglev::RetrievalOutcome.new(
      results: results,
      minimum_similarity: @outcome.minimum_similarity,
      examined_count: @outcome.examined_count,
      accepted_count: @outcome.accepted_count,
      rejected_count: @outcome.rejected_count,
      best_similarity: @outcome.best_similarity
    )
  end
end

class ChunkProjectionGenerationAdapter
  attr_reader :prompts

  def initialize(text = "Generated answer.")
    @text = text
    @prompts = []
  end

  def generate(prompt)
    @prompts << prompt
    @text
  end
end

RSpec.describe "Model answer owner/chunk projection" do
  around do |example|
    original = Maglev.configuration
    configuration = Maglev::Configuration.new
    configuration.embedding_dimensions = 3
    Maglev.instance_variable_set(:@configuration, configuration)
    example.run
  ensure
    Maglev.instance_variable_set(:@configuration, original)
  end

  describe "chunks_per_owner parameter" do
    it "accepts positive chunks_per_owner" do
      customer1 = ChunkProjectionCustomer.new(1)
      customer2 = ChunkProjectionCustomer.new(2)
      outcome = Maglev::RetrievalOutcome.new(
        results: [
          Maglev::SearchResult.new(owner: customer1, content: "c1-chunk0", source: "snapshot", distance: 0.1, chunk_index: 0),
          Maglev::SearchResult.new(owner: customer1, content: "c1-chunk1", source: "snapshot", distance: 0.2, chunk_index: 1),
          Maglev::SearchResult.new(owner: customer2, content: "c2-chunk0", source: "snapshot", distance: 0.3, chunk_index: 0)
        ],
        minimum_similarity: nil,
        examined_count: 3,
        accepted_count: 3,
        rejected_count: 0,
        best_similarity: 0.9
      )
      retriever = FakeChunkProjectionRetriever.new(outcome)
      generator = ChunkProjectionGenerationAdapter.new

      response = Maglev::Answerer.new(ChunkProjectionCustomer, retriever: retriever, generation_adapter: generator)
        .ask("test question", limit: 2, chunks_per_owner: 2)

      expect(response).to be_a(Maglev::Response)
      expect(response.sources.size).to eq(3)
    end

    it "rejects non-positive chunks_per_owner" do
      outcome = Maglev::RetrievalOutcome.new(
        results: [],
        minimum_similarity: nil,
        examined_count: 0,
        accepted_count: 0,
        rejected_count: 0,
        best_similarity: nil
      )
      retriever = FakeChunkProjectionRetriever.new(outcome)

      expect do
        Maglev::Answerer.new(ChunkProjectionCustomer, retriever: retriever, generation_adapter: ChunkProjectionGenerationAdapter.new)
          .ask("test", limit: 5, chunks_per_owner: 0)
      end.to raise_error(ArgumentError, /chunks_per_owner/)
    end

    it "rejects negative chunks_per_owner" do
      outcome = Maglev::RetrievalOutcome.new(
        results: [],
        minimum_similarity: nil,
        examined_count: 0,
        accepted_count: 0,
        rejected_count: 0,
        best_similarity: nil
      )
      retriever = FakeChunkProjectionRetriever.new(outcome)

      expect do
        Maglev::Answerer.new(ChunkProjectionCustomer, retriever: retriever, generation_adapter: ChunkProjectionGenerationAdapter.new)
          .ask("test", limit: 5, chunks_per_owner: -1)
      end.to raise_error(ArgumentError, /chunks_per_owner/)
    end

    it "defaults chunks_per_owner to 1" do
      customer1 = ChunkProjectionCustomer.new(1)
      customer2 = ChunkProjectionCustomer.new(2)
      outcome = Maglev::RetrievalOutcome.new(
        results: [
          Maglev::SearchResult.new(owner: customer1, content: "c1-chunk0", source: "snapshot", distance: 0.1, chunk_index: 0),
          Maglev::SearchResult.new(owner: customer1, content: "c1-chunk1", source: "snapshot", distance: 0.2, chunk_index: 1),
          Maglev::SearchResult.new(owner: customer2, content: "c2-chunk0", source: "snapshot", distance: 0.3, chunk_index: 0)
        ],
        minimum_similarity: nil,
        examined_count: 3,
        accepted_count: 3,
        rejected_count: 0,
        best_similarity: 0.9
      )
      retriever = FakeChunkProjectionRetriever.new(outcome)
      generator = ChunkProjectionGenerationAdapter.new

      response = Maglev::Answerer.new(ChunkProjectionCustomer, retriever: retriever, generation_adapter: generator)
        .ask("test question", limit: 5)

      expect(response.sources.size).to eq(2)
    end
  end

  describe "limit means owners for class ask" do
    it "selects at most limit owners" do
      customers = 5.times.map { |i| ChunkProjectionCustomer.new(i + 1) }
      results = customers.flat_map.with_index do |customer, i|
        Maglev::SearchResult.new(owner: customer, content: "chunk-#{i}", source: "snapshot", distance: 0.1 * (i + 1), chunk_index: 0)
      end
      outcome = Maglev::RetrievalOutcome.new(
        results: results,
        minimum_similarity: nil,
        examined_count: 5,
        accepted_count: 5,
        rejected_count: 0,
        best_similarity: 0.9
      )
      retriever = FakeChunkProjectionRetriever.new(outcome)
      generator = ChunkProjectionGenerationAdapter.new

      response = Maglev::Answerer.new(ChunkProjectionCustomer, retriever: retriever, generation_adapter: generator)
        .ask("test", limit: 2)

      expect(response.sources.map { |s| s[:owner_id] }.uniq.size).to be <= 2
    end
  end

  describe "deterministic ordering" do
    it "orders owners by best chunk distance" do
      customer1 = ChunkProjectionCustomer.new(1)
      customer2 = ChunkProjectionCustomer.new(2)
      outcome = Maglev::RetrievalOutcome.new(
        results: [
          Maglev::SearchResult.new(owner: customer2, content: "c2", source: "snapshot", distance: 0.1, chunk_index: 0),
          Maglev::SearchResult.new(owner: customer1, content: "c1", source: "snapshot", distance: 0.3, chunk_index: 0)
        ],
        minimum_similarity: nil,
        examined_count: 2,
        accepted_count: 2,
        rejected_count: 0,
        best_similarity: 0.9
      )
      retriever = FakeChunkProjectionRetriever.new(outcome)
      generator = ChunkProjectionGenerationAdapter.new

      response = Maglev::Answerer.new(ChunkProjectionCustomer, retriever: retriever, generation_adapter: generator)
        .ask("test", limit: 2, chunks_per_owner: 1)

      expect(response.sources.first[:owner_id]).to eq(2)
      expect(response.sources.last[:owner_id]).to eq(1)
    end

    it "selects the owner with the highest similarity when limited" do
      customer1 = ChunkProjectionCustomer.new(1)
      customer2 = ChunkProjectionCustomer.new(2)
      outcome = Maglev::RetrievalOutcome.new(
        results: [
          Maglev::SearchResult.new(owner: customer1, content: "worse", source: "snapshot", distance: 0.4, chunk_index: 0),
          Maglev::SearchResult.new(owner: customer2, content: "best", source: "snapshot", distance: 0.1, chunk_index: 0)
        ],
        minimum_similarity: nil,
        examined_count: 2,
        accepted_count: 2,
        rejected_count: 0,
        best_similarity: 0.9
      )

      response = Maglev::Answerer.new(
        ChunkProjectionCustomer,
        retriever: FakeChunkProjectionRetriever.new(outcome),
        generation_adapter: ChunkProjectionGenerationAdapter.new
      ).ask("test", limit: 1)

      expect(response.sources.map { |source| source[:owner_id] }).to eq([2])
    end
  end
end
