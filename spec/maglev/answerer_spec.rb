# frozen_string_literal: true

require "spec_helper"
require "maglev/answerer"
require "maglev/search_result"

class AnswerCustomer
  def self.name
    "AnswerCustomer"
  end

  attr_reader :id

  def initialize(id)
    @id = id
  end
end

class FakeAnswerRetriever
  attr_reader :calls

  def initialize(results)
    @results = results
    @calls = []
  end

  def search(query, limit:, owner: nil)
    @calls << {query: query, limit: limit, owner: owner}
    @results
  end
end

class FakeAnswerGenerationAdapter
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

RSpec.describe Maglev::Answerer do
  it "retrieves context, generates a grounded response, and keeps traceable sources" do
    customer = AnswerCustomer.new(42)
    retriever = FakeAnswerRetriever.new([
      Maglev::SearchResult.new(owner: customer, content: "support tickets increased", source: "snapshot", distance: 0.15, chunk_index: 0)
    ])
    generator = FakeAnswerGenerationAdapter.new("Customer 42 is at risk [S1].")

    response = described_class.new(AnswerCustomer, retriever: retriever, generation_adapter: generator)
      .ask("Who is at risk?", limit: 5)

    expect(retriever.calls).to eq([{query: "Who is at risk?", limit: 5, owner: nil}])
    expect(generator.prompts.first).to include("Who is at risk?")
    expect(generator.prompts.first).to include("[S1] AnswerCustomer#42")
    expect(response.text).to eq("Customer 42 is at risk [S1].")
    expect(response.sources.first[:marker]).to eq("[S1]")
    expect(response.metadata).to include(question: "Who is at risk?", owner_scope: nil, source_count: 1)
  end

  it "scopes instance questions to the supplied owner" do
    customer = AnswerCustomer.new(42)
    retriever = FakeAnswerRetriever.new([
      Maglev::SearchResult.new(owner: customer, content: "late invoices", source: "snapshot", distance: 0.2)
    ])

    described_class.new(AnswerCustomer, retriever: retriever, generation_adapter: FakeAnswerGenerationAdapter.new)
      .ask("Why unhappy?", limit: 3, owner: customer)

    expect(retriever.calls).to eq([{query: "Why unhappy?", limit: 3, owner: customer}])
  end

  it "includes multiple retrieved chunks for an instance question" do
    customer = AnswerCustomer.new(42)
    retriever = FakeAnswerRetriever.new([
      Maglev::SearchResult.new(owner: customer, content: "late invoices", source: "snapshot", distance: 0.1, chunk_index: 0),
      Maglev::SearchResult.new(owner: customer, content: "support escalations", source: "snapshot", distance: 0.2, chunk_index: 1)
    ])

    response = described_class.new(AnswerCustomer, retriever: retriever, generation_adapter: FakeAnswerGenerationAdapter.new)
      .ask("Why unhappy?", limit: 3, owner: customer)

    expect(response.sources.map { |source| source[:chunk_index] }).to eq([0, 1])
  end

  it "returns insufficient context without calling generation when retrieval is empty" do
    retriever = FakeAnswerRetriever.new([])
    generator = FakeAnswerGenerationAdapter.new

    response = described_class.new(AnswerCustomer, retriever: retriever, generation_adapter: generator)
      .ask("What changed?", limit: 5)

    expect(response.text).to eq("Insufficient context to answer the question.")
    expect(response.sources).to eq([])
    expect(response.metadata).to include(question: "What changed?", reason: "insufficient_context")
    expect(generator.prompts).to eq([])
  end
end
