# frozen_string_literal: true

require "spec_helper"
require "maglev/retrieval_outcome"
require "maglev/search_result"

RSpec.describe Maglev::RetrievalOutcome do
  let(:owner) { double("owner") }
  let(:result1) { Maglev::SearchResult.new(owner: owner, content: "first", source: "snapshot", distance: 0.1, chunk_index: 0) }
  let(:result2) { Maglev::SearchResult.new(owner: owner, content: "second", source: "snapshot", distance: 0.3, chunk_index: 1) }

  it "is immutable and frozen" do
    outcome = described_class.new(
      results: [result1],
      examined_count: 5,
      accepted_count: 1,
      rejected_count: 4,
      minimum_similarity: nil,
      best_similarity: 0.9
    )

    expect(outcome).to be_frozen
    expect { outcome.results << result2 }.to raise_error(FrozenError)
  end

  it "exposes all metadata attributes" do
    outcome = described_class.new(
      results: [result1],
      examined_count: 3,
      accepted_count: 1,
      rejected_count: 2,
      minimum_similarity: 0.5,
      best_similarity: 0.9
    )

    expect(outcome.results).to eq([result1])
    expect(outcome.examined_count).to eq(3)
    expect(outcome.accepted_count).to eq(1)
    expect(outcome.rejected_count).to eq(2)
    expect(outcome.minimum_similarity).to eq(0.5)
    expect(outcome.best_similarity).to eq(0.9)
  end

  it "returns nil for best_similarity when no candidates examined" do
    outcome = described_class.new(
      results: [],
      examined_count: 0,
      accepted_count: 0,
      rejected_count: 0,
      minimum_similarity: 0.5,
      best_similarity: nil
    )

    expect(outcome.best_similarity).to be_nil
  end

  it "provides a reason for empty results when threshold rejected all" do
    outcome = described_class.new(
      results: [],
      examined_count: 5,
      accepted_count: 0,
      rejected_count: 5,
      minimum_similarity: 0.8,
      best_similarity: 0.6
    )

    expect(outcome.empty_reason).to eq(:threshold_rejected)
    expect(outcome.threshold_rejected?).to be true
  end

  it "provides a reason for empty results when no candidates existed" do
    outcome = described_class.new(
      results: [],
      examined_count: 0,
      accepted_count: 0,
      rejected_count: 0,
      minimum_similarity: nil,
      best_similarity: nil
    )

    expect(outcome.empty_reason).to eq(:no_candidates)
    expect(outcome.no_candidates?).to be true
  end

  it "has nil empty_reason when results are present" do
    outcome = described_class.new(
      results: [result1],
      examined_count: 1,
      accepted_count: 1,
      rejected_count: 0,
      minimum_similarity: nil,
      best_similarity: 0.9
    )

    expect(outcome.empty_reason).to be_nil
  end
end
