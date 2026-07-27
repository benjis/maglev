# frozen_string_literal: true

require "spec_helper"
require "maglev/knowledge_config"

class TestKnowledgeRecord
  def self.attribute_names
    %w[id name industry description internal_note]
  end
end

RSpec.describe Maglev::KnowledgeConfig do
  it "normalizes independent content, context, prohibited, and tag declarations" do
    config = described_class.build(TestKnowledgeRecord) do
      content :name, "description", :name
      context :industry, "industry"
      prohibit :internal_note, "internal_note"
      tags :customer, "commercial", :customer
    end

    expect(config.content_attributes).to eq(%w[name description])
    expect(config.context_attributes).to eq(["industry"])
    expect(config.prohibited_attributes).to eq(["internal_note"])
    expect(config.tags).to eq(%w[customer commercial])
  end

  it "rejects unknown knowledge attributes with a Maglev-specific error" do
    expect do
      described_class.build(TestKnowledgeRecord) do
        content :unknown_field
      end
    end.to raise_error(Maglev::ConfigurationError, /unknown_field/)
  end

  it "rejects content and context conflicts deterministically" do
    expect do
      described_class.build(TestKnowledgeRecord) do
        content :name
        context :name
      end
    end.to raise_error(Maglev::ConfigurationError, /both content and context.*name/i)
  end

  it "requires at least one semantic content field" do
    expect do
      described_class.build(TestKnowledgeRecord) do
        context :industry
      end
    end.to raise_error(Maglev::ConfigurationError, /requires at least one content/i)
  end

  it "returns immutable caller-facing collections" do
    config = described_class.build(TestKnowledgeRecord) do
      content :name
      context :industry
      prohibit :internal_note
      tags :customer
    end

    expect(config).to be_frozen
    expect(config.content_attributes).to be_frozen
    expect(config.context_attributes).to be_frozen
    expect(config.prohibited_attributes).to be_frozen
    expect(config.tags).to be_frozen
    expect { config.content_attributes << "description" }.to raise_error(FrozenError)
  end
end
