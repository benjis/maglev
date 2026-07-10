# frozen_string_literal: true

require "spec_helper"
require "maglev/knowledge_config"
require "maglev/snapshot_builder"

class TestSnapshotRecord
  ATTRIBUTES = %w[id name industry description internal_note].freeze

  attr_reader(*ATTRIBUTES.map(&:to_sym))

  def self.attribute_names
    ATTRIBUTES
  end

  def initialize(attributes)
    attributes.each do |name, value|
      instance_variable_set(:"@#{name}", value)
    end
  end
end

RSpec.describe Maglev::SnapshotBuilder do
  it "builds deterministic human-readable text from exposed non-nil fields" do
    config = Maglev::KnowledgeConfig.build(TestSnapshotRecord) do
      expose :name, :industry, :description
      hide :internal_note
      tags :customer, :commercial
    end
    record = TestSnapshotRecord.new(
      id: 123,
      name: "Acme Pty Ltd",
      industry: "Retail",
      description: nil,
      internal_note: "never include me"
    )

    first_snapshot = described_class.new(record, config).build
    second_snapshot = described_class.new(record, config).build

    expect(first_snapshot.to_s).to eq(<<~TEXT.chomp)
      TestSnapshotRecord#123
      name: Acme Pty Ltd
      industry: Retail
      tags: customer, commercial
    TEXT
    expect(second_snapshot.to_s).to eq(first_snapshot.to_s)
    expect(first_snapshot.to_s).not_to include("description:")
    expect(first_snapshot.to_s).not_to include("internal_note")
  end

  it "uses new_record when an id is not present" do
    config = Maglev::KnowledgeConfig.build(TestSnapshotRecord) do
      expose :name
    end
    record = TestSnapshotRecord.new(id: nil, name: "Unsaved")

    snapshot = described_class.new(record, config).build

    expect(snapshot.to_s).to start_with("TestSnapshotRecord#new_record")
  end
end
