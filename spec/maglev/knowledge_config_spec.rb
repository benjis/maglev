# frozen_string_literal: true

require "spec_helper"
require "maglev/knowledge_config"

class TestKnowledgeRecord
  def self.attribute_names
    %w[id name industry description internal_note]
  end
end

RSpec.describe Maglev::KnowledgeConfig do
  it "normalizes exposed, hidden, and tag declarations" do
    config = described_class.build(TestKnowledgeRecord) do
      expose :name, "industry", :name
      hide :internal_note, "internal_note"
      tags :customer, "commercial", :customer
    end

    expect(config.exposed_attributes).to eq(%w[name industry])
    expect(config.hidden_attributes).to eq(["internal_note"])
    expect(config.tags).to eq(%w[customer commercial])
  end

  it "rejects unknown exposed attributes with a Maglev-specific error" do
    expect do
      described_class.build(TestKnowledgeRecord) do
        expose :unknown_field
      end
    end.to raise_error(Maglev::ConfigurationError, /unknown_field/)
  end

  it "rejects expose and hide conflicts with a Maglev-specific error" do
    expect do
      described_class.build(TestKnowledgeRecord) do
        expose :name
        hide :name
      end
    end.to raise_error(Maglev::ConfigurationError, /both exposed and hidden/)
  end

  it "returns immutable caller-facing collections" do
    config = described_class.build(TestKnowledgeRecord) do
      expose :name
      hide :internal_note
      tags :customer
    end

    expect(config).to be_frozen
    expect(config.exposed_attributes).to be_frozen
    expect(config.hidden_attributes).to be_frozen
    expect(config.tags).to be_frozen
    expect { config.exposed_attributes << "industry" }.to raise_error(FrozenError)
  end
end
