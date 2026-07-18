# frozen_string_literal: true

require "spec_helper"
require "maglev/retrieval_result"

RSpec.describe Maglev::RetrievalResult do
  it "is immutable and exposes provider-neutral retrieval evidence" do
    source = Maglev::SearchResult.new(owner: "owner", content: "evidence", source: "attribute:name", distance: 0.1)
    result = described_class.new(query: "why", considered: [source], selected: [source], rejected: [],
      context: "[S1] evidence", budgets: {characters: 13}, reasons: [], timings: {total_ms: 1.2}, trace_id: "trace-7")

    expect(result).to have_attributes(query: "why", selected: [source], trace_id: "trace-7")
    expect(result.selected.first.similarity).to eq(0.9)
    expect(result).to be_frozen
    expect(result.metadata).not_to include(:query, :content)
  end
end
