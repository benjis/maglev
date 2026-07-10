# frozen_string_literal: true

require "spec_helper"
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

      @rows
    end
  end
end

FakeSearchRow = Struct.new(:owner, :content, :source, :distance)

RSpec.describe Maglev::Retriever do
  it "returns typed results capped to one chunk per owner" do
    adapter = FakeQueryEmbeddingAdapter.new
    chunk_model = FakeSearchChunk.with_rows([
      FakeSearchRow.new("customer-1", "first", "snapshot", 0.1),
      FakeSearchRow.new("customer-1", "duplicate", "snapshot", 0.2),
      FakeSearchRow.new("customer-2", "second", "snapshot", 0.3)
    ])

    results = described_class.new(FakeSearchOwner, chunk_model: chunk_model, embedding_adapter: adapter).search("support", limit: 2)

    expect(adapter.calls).to eq(["support"])
    expect(chunk_model.conditions).to eq([{owner_model_name: "FakeSearchOwner"}])
    expect(results.map(&:owner)).to eq(["customer-1", "customer-2"])
    expect(results.map(&:content)).to eq(%w[first second])
    expect(results.first.similarity).to eq(0.9)
  end

  it "can scope retrieval to a single owner" do
    owner = "customer-1"
    chunk_model = FakeSearchChunk.with_rows([
      FakeSearchRow.new(owner, "first", "snapshot", 0.1)
    ])

    described_class.new(FakeSearchOwner, chunk_model: chunk_model, embedding_adapter: FakeQueryEmbeddingAdapter.new)
      .search("support", limit: 2, owner: owner)

    expect(chunk_model.conditions).to eq([{owner_model_name: "FakeSearchOwner"}, {owner: owner}])
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
      {owner_model_name: "FakeSearchOwner"},
      {owner_id: "authorized-owner-ids"}
    ])
  end
end
