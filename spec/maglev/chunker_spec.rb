# frozen_string_literal: true

require "spec_helper"
require "maglev/chunker"

RSpec.describe Maglev::Chunker do
  it "returns deterministic chunks under the configured character budget" do
    text = <<~TEXT
      Customer#123
      name: Acme Pty Ltd

      industry: Retail
      description: Long term customer with repeated support problems.
    TEXT

    chunks = described_class.new(max_characters: 55).call(text)

    expect(chunks).to eq([
      "Customer#123\nname: Acme Pty Ltd",
      "industry: Retail",
      "description: Long term customer with repeated support",
      "problems."
    ])
  end

  it "drops blank chunks" do
    expect(described_class.new(max_characters: 10).call("\n\n")).to eq([])
  end
end
