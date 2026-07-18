# frozen_string_literal: true

require "spec_helper"
require "maglev/search_result"

RSpec.describe Maglev::SearchResult do
  describe "#similarity" do
    it "normalizes distance to similarity" do
      result = described_class.new(owner: nil, content: "test", source: "snapshot", distance: 0.15)
      expect(result.similarity).to eq(0.85)
    end

    it "clamps similarity to 0.0..1.0" do
      result = described_class.new(owner: nil, content: "test", source: "snapshot", distance: -0.5)
      expect(result.similarity).to eq(1.0)
    end

    it "clamps similarity at the lower bound" do
      result = described_class.new(owner: nil, content: "test", source: "snapshot", distance: 1.5)
      expect(result.similarity).to eq(0.0)
    end

    it "returns nil when distance is nil" do
      result = described_class.new(owner: nil, content: "test", source: "snapshot", distance: nil)
      expect(result.similarity).to be_nil
    end

    it "returns 0.0 for distance exactly 1.0" do
      result = described_class.new(owner: nil, content: "test", source: "snapshot", distance: 1.0)
      expect(result.similarity).to eq(0.0)
    end

    it "returns 1.0 for distance exactly 0.0" do
      result = described_class.new(owner: nil, content: "test", source: "snapshot", distance: 0.0)
      expect(result.similarity).to eq(1.0)
    end
  end
end
