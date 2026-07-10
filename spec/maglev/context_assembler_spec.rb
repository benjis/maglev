# frozen_string_literal: true

require "spec_helper"
require "maglev/context_assembler"
require "maglev/search_result"

ContextOwner = Struct.new(:id, :name) unless defined?(ContextOwner)

RSpec.describe Maglev::ContextAssembler do
  it "assembles source-marked context and source metadata within configured budgets" do
    owner = ContextOwner.new(7, "Acme")
    results = [
      Maglev::SearchResult.new(owner: owner, content: "a" * 24, source: "snapshot", distance: 0.3, chunk_index: 1),
      Maglev::SearchResult.new(owner: owner, content: "b" * 24, source: "snapshot", distance: 0.1, chunk_index: 0),
      Maglev::SearchResult.new(owner: ContextOwner.new(8, "Beta"), content: "c" * 24, source: "snapshot", distance: 0.2, chunk_index: 0)
    ]

    context = described_class.new(max_characters: 140, per_owner_characters: 50).assemble(results)

    expect(context.text).to include("[S1] ContextOwner#7 chunk 0 source: snapshot")
    expect(context.text).to include("[S2] ContextOwner#8 chunk 0 source: snapshot")
    expect(context.text).not_to include("chunk 1")
    expect(context.sources).to eq([
      {
        marker: "[S1]",
        owner_type: "ContextOwner",
        owner_id: 7,
        source: "snapshot",
        chunk_index: 0,
        content: "b" * 24,
        distance: 0.1,
        similarity: 0.9
      },
      {
        marker: "[S2]",
        owner_type: "ContextOwner",
        owner_id: 8,
        source: "snapshot",
        chunk_index: 0,
        content: "c" * 24,
        distance: 0.2,
        similarity: 0.8
      }
    ])
    expect(context.metadata).to eq({context_characters: context.text.length, source_count: 2})
  end

  it "uses actual separator length when enforcing the global context budget" do
    first = Maglev::SearchResult.new(owner: ContextOwner.new(1, "Acme"), content: "a" * 24, source: "snapshot", distance: 0.1, chunk_index: 0)
    second = Maglev::SearchResult.new(owner: ContextOwner.new(2, "Beta"), content: "b" * 24, source: "snapshot", distance: 0.2, chunk_index: 0)

    context = described_class.new(max_characters: 139, per_owner_characters: 50).assemble([first, second])

    expect(context.sources.map { |source| source[:marker] }).to eq(["[S1]", "[S2]"])
    expect(context.text.length).to eq(139)
  end
end
