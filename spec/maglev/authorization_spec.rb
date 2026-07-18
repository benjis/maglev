# frozen_string_literal: true

require "spec_helper"
require "maglev/answerer"
require "maglev/retriever"
require "maglev/search_result"
require "maglev/retrieval_outcome"

class AuthzCustomer
  def self.name = "AuthzCustomer"
end

AuthzOwner = Struct.new(:id, :allowed)

class AuthzRetriever
  attr_reader :calls

  def initialize(results)
    @results = results
    @calls = []
  end

  def retrieval_outcome(query, limit:, owner: nil, user: nil, minimum_similarity: nil, chunks_per_owner: 1)
    @calls << {query: query, limit: limit, owner: owner, user: user}
    Maglev::RetrievalOutcome.new(
      results: @results,
      minimum_similarity: minimum_similarity,
      examined_count: @results.size,
      accepted_count: @results.size,
      rejected_count: 0,
      best_similarity: @results.filter_map(&:similarity).max
    )
  end
end

class AuthzGenerationAdapter
  attr_reader :prompts

  def initialize
    @prompts = []
  end

  def generate(prompt)
    @prompts << prompt
    "answer"
  end
end

class TestAuthorizationAdapter
  def scope(model:, user:)
    user.fetch(model)
  end

  def authorize(record:, user:)
    raise Maglev::AuthorizationError, "not allowed" unless user.include?(record)
  end
end

RSpec.describe "Maglev authorization" do
  around do |example|
    original = Maglev.configuration.authorization_adapter
    Maglev.configuration.authorization_adapter = TestAuthorizationAdapter.new
    example.run
  ensure
    Maglev.configuration.authorization_adapter = original
  end

  it "authorizes instance-level ask before context assembly or generation" do
    owner = AuthzOwner.new(1, false)
    retriever = AuthzRetriever.new([
      Maglev::SearchResult.new(owner: owner, content: "secret", source: "snapshot", distance: 0.1)
    ])
    generator = AuthzGenerationAdapter.new

    expect do
      Maglev::Answerer.new(AuthzCustomer, retriever: retriever, generation_adapter: generator)
        .ask("secret?", limit: 1, owner: owner, user: [])
    end.to raise_error(Maglev::AuthorizationError)

    expect(retriever.calls).to eq([])
    expect(generator.prompts).to eq([])
  end

  it "keeps unauthorized retrieved class-level chunks out of generation" do
    allowed = AuthzOwner.new(1, true)
    blocked = AuthzOwner.new(2, false)
    retriever = AuthzRetriever.new([
      Maglev::SearchResult.new(owner: allowed, content: "public", source: "snapshot", distance: 0.1),
      Maglev::SearchResult.new(owner: blocked, content: "secret", source: "snapshot", distance: 0.2)
    ])
    generator = AuthzGenerationAdapter.new

    response = Maglev::Answerer.new(AuthzCustomer, retriever: retriever, generation_adapter: generator)
      .ask("what?", limit: 2, user: [allowed])

    expect(response.sources.map { |source| source[:owner_id] }).to eq([1])
    expect(generator.prompts.first).to include("public")
    expect(generator.prompts.first).not_to include("secret")
  end

  it "allows all records explicitly when no authorization adapter is configured" do
    Maglev.configuration.authorization_adapter = nil
    owner = AuthzOwner.new(1, true)
    retriever = AuthzRetriever.new([
      Maglev::SearchResult.new(owner: owner, content: "public", source: "snapshot", distance: 0.1)
    ])

    response = Maglev::Answerer.new(AuthzCustomer, retriever: retriever, generation_adapter: AuthzGenerationAdapter.new)
      .ask("what?", limit: 1)

    expect(response.sources.first[:owner_id]).to eq(1)
  end
end
