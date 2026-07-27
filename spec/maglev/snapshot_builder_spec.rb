# frozen_string_literal: true

require "spec_helper"
require "maglev/knowledge_config"
require "maglev/snapshot_builder"

class TestSnapshotRecord
  ATTRIBUTES = %w[id name industry description internal_note unsupported unavailable].freeze

  attr_reader(*ATTRIBUTES.map(&:to_sym))

  def self.attribute_names
    ATTRIBUTES
  end

  def initialize(attributes)
    attributes.each do |name, value|
      instance_variable_set(:"@#{name}", value)
    end
  end

  def unavailable
    raise "not authorized"
  end
end

RSpec.describe Maglev::SnapshotBuilder do
  it "builds embeddings from content while retaining context as metadata" do
    config = Maglev::KnowledgeConfig.build(TestSnapshotRecord) do
      content :name, :description, :unsupported, :unavailable
      context :industry
      prohibit :internal_note
      tags :customer, :commercial
    end
    record = TestSnapshotRecord.new(
      id: 123,
      name: "Acme Pty Ltd",
      industry: "Retail",
      description: nil,
      internal_note: "never include me",
      unsupported: ["never stringify me"],
      unavailable: nil
    )

    first_snapshot = described_class.new(record, config).build
    second_snapshot = described_class.new(record, config).build

    expect(first_snapshot.to_s).to eq(<<~TEXT.chomp)
      TestSnapshotRecord#123
      name: Acme Pty Ltd
    TEXT
    expect(second_snapshot.to_s).to eq(first_snapshot.to_s)
    expect(first_snapshot.to_s).not_to include("description:")
    expect(first_snapshot.to_s).not_to include("industry:")
    expect(first_snapshot.to_s).not_to include("internal_note")
    expect(first_snapshot.to_s).not_to include("never stringify me")
    expect(first_snapshot.metadata[:knowledge_context]).to eq(
      "industry" => "Retail",
      "tags" => %w[customer commercial]
    )
    expect(first_snapshot.metadata[:diagnostics]).to include(
      {field: "description", role: :content, reason: :empty},
      {field: "unsupported", role: :content, reason: :unsupported},
      {field: "unavailable", role: :content, reason: :unavailable}
    )
  end

  it "uses new_record when an id is not present" do
    config = Maglev::KnowledgeConfig.build(TestSnapshotRecord) do
      content :name
    end
    record = TestSnapshotRecord.new(id: nil, name: "Unsaved")

    snapshot = described_class.new(record, config).build

    expect(snapshot.to_s).to start_with("TestSnapshotRecord#new_record")
    expect(snapshot.metadata[:attribution]).to eq(owner_type: "TestSnapshotRecord", owner_id: "new_record")
  end
end
