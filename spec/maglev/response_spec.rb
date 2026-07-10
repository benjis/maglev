# frozen_string_literal: true

require "spec_helper"
require "maglev/response"

RSpec.describe Maglev::Response do
  it "exposes generated text, traceable sources, metadata, and string coercion" do
    response = described_class.new(
      text: "Acme is at risk because support volume increased.",
      sources: [{marker: "[S1]", owner_type: "Customer", owner_id: 1}],
      metadata: {question: "Who is at risk?"}
    )

    expect(response.text).to eq("Acme is at risk because support volume increased.")
    expect(response.sources).to eq([{marker: "[S1]", owner_type: "Customer", owner_id: 1}])
    expect(response.metadata).to eq({question: "Who is at risk?"})
    expect(response.to_s).to eq(response.text)
    expect(response).to be_frozen
  end

  it "builds a deterministic insufficient-context response" do
    response = described_class.insufficient_context(question: "What changed?")

    expect(response.text).to eq("Insufficient context to answer the question.")
    expect(response.sources).to eq([])
    expect(response.metadata).to eq({question: "What changed?", reason: "insufficient_context"})
  end
end
