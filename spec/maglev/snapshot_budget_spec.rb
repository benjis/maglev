# frozen_string_literal: true

require "spec_helper"
require "maglev/knowledge_config"
require "maglev/snapshot_builder"
require "maglev/snapshot"
require "maglev/chunker"

class BudgetTestRecord
  ATTRIBUTES = %w[id name description body].freeze

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

RSpec.describe "Snapshot and chunk budgets" do
  around do |example|
    original = Maglev.configuration
    configuration = Maglev::Configuration.new
    configuration.embedding_dimensions = 3
    Maglev.instance_variable_set(:@configuration, configuration)
    example.run
  ensure
    Maglev.instance_variable_set(:@configuration, original)
  end

  describe "budget configuration defaults" do
    it "has the required default values" do
      config = Maglev::Configuration.new

      expect(config.snapshot_attribute_max_characters).to eq(20_000)
      expect(config.snapshot_related_record_max_characters).to eq(50_000)
      expect(config.snapshot_max_characters).to eq(100_000)
      expect(config.snapshot_max_chunks).to eq(100)
    end

    it "rejects non-positive budget values" do
      expect { Maglev.configuration.snapshot_attribute_max_characters = 0 }.to raise_error(ArgumentError)
      expect { Maglev.configuration.snapshot_related_record_max_characters = -1 }.to raise_error(ArgumentError)
      expect { Maglev.configuration.snapshot_max_characters = "large" }.to raise_error(ArgumentError)
      expect { Maglev.configuration.snapshot_max_chunks = nil }.to raise_error(ArgumentError)
    end

    it "allows overriding budget defaults" do
      config = Maglev::Configuration.new
      config.snapshot_attribute_max_characters = 5_000
      config.snapshot_max_characters = 50_000
      config.snapshot_max_chunks = 50

      expect(config.snapshot_attribute_max_characters).to eq(5_000)
      expect(config.snapshot_max_characters).to eq(50_000)
      expect(config.snapshot_max_chunks).to eq(50)
    end
  end

  describe "per-attribute truncation" do
    it "truncates an attribute exceeding the budget" do
      Maglev.configuration.snapshot_attribute_max_characters = 10
      config = Maglev::KnowledgeConfig.build(BudgetTestRecord) do
        expose :name, :description
      end
      record = BudgetTestRecord.new(id: 1, name: "a" * 20, description: "short")

      snapshot = Maglev::SnapshotBuilder.new(record, config).build

      expect(snapshot.to_s).to include("name: #{"a" * 10}")
      expect(snapshot.to_s).not_to include("a" * 11)
    end

    it "preserves attribute content within budget" do
      Maglev.configuration.snapshot_attribute_max_characters = 100
      config = Maglev::KnowledgeConfig.build(BudgetTestRecord) do
        expose :name, :description
      end
      record = BudgetTestRecord.new(id: 1, name: "short", description: "also short")

      snapshot = Maglev::SnapshotBuilder.new(record, config).build

      expect(snapshot.to_s).to include("name: short")
      expect(snapshot.to_s).to include("description: also short")
    end
  end

  describe "whole-snapshot truncation" do
    it "truncates the whole snapshot to the max characters budget" do
      Maglev.configuration.snapshot_max_characters = 50
      config = Maglev::KnowledgeConfig.build(BudgetTestRecord) do
        expose :name, :description
      end
      record = BudgetTestRecord.new(id: 1, name: "a" * 30, description: "b" * 30)

      snapshot = Maglev::SnapshotBuilder.new(record, config).build

      expect(snapshot.to_s.length).to be <= 50
    end
  end

  describe "chunk cap" do
    it "returns at most snapshot_max_chunks chunks" do
      Maglev.configuration.chunk_size = 5
      Maglev.configuration.snapshot_max_chunks = 3
      config = Maglev::KnowledgeConfig.build(BudgetTestRecord) do
        expose :name, :description
      end
      record = BudgetTestRecord.new(id: 1, name: "a" * 20, description: "b" * 20)

      snapshot = Maglev::SnapshotBuilder.new(record, config).build
      chunks = Maglev::Chunker.new(max_characters: Maglev.configuration.chunk_size, max_chunks: Maglev.configuration.snapshot_max_chunks).call(snapshot.to_s)

      expect(chunks.length).to be <= 3
    end
  end

  describe "budget metadata" do
    it "tracks truncation in snapshot metadata" do
      Maglev.configuration.snapshot_attribute_max_characters = 5
      config = Maglev::KnowledgeConfig.build(BudgetTestRecord) do
        expose :name
      end
      record = BudgetTestRecord.new(id: 1, name: "a" * 20)

      snapshot = Maglev::SnapshotBuilder.new(record, config).build

      expect(snapshot.truncated?).to be true
      expect(snapshot.metadata[:sources]).to be_an(Array)
      expect(snapshot.metadata[:limits]).to include(attribute_characters: 5)
      expect { snapshot.metadata[:sources] << {} }.to raise_error(FrozenError)
    end

    it "reports no truncation when content is within budget" do
      Maglev.configuration.snapshot_attribute_max_characters = 100
      config = Maglev::KnowledgeConfig.build(BudgetTestRecord) do
        expose :name
      end
      record = BudgetTestRecord.new(id: 1, name: "short")

      snapshot = Maglev::SnapshotBuilder.new(record, config).build

      expect(snapshot.truncated?).to be false
    end

    it "records rich text, attachment, and related-record truncation with paths" do
      Maglev.configuration.snapshot_attribute_max_characters = 3
      Maglev.configuration.snapshot_related_record_max_characters = 4
      budget = Maglev::SnapshotBudget.new

      expect(budget.truncate("rich", kind: :rich_text, path: "rich_text.notes")).to eq("ric")
      expect(budget.truncate("blob", kind: :attachment, path: "attachments.file.1")).to eq("blo")
      expect(budget.truncate("child", kind: :related_record, path: "relations.items.7")).to eq("chil")

      expect(budget.metadata[:sources]).to include(
        include(kind: :rich_text, path: "rich_text.notes", original_characters: 4, retained_characters: 3),
        include(kind: :attachment, path: "attachments.file.1", original_characters: 4, retained_characters: 3),
        include(kind: :related_record, path: "relations.items.7", original_characters: 5, retained_characters: 4)
      )
    end

    it "uses character counts for multibyte text and does not truncate at the exact boundary" do
      Maglev.configuration.snapshot_attribute_max_characters = 3
      budget = Maglev::SnapshotBudget.new

      expect(budget.truncate("日本語", kind: :attribute, path: "name")).to eq("日本語")
      expect(budget.metadata[:sources]).to be_empty
      expect(budget.truncate("日本語文", kind: :attribute, path: "description")).to eq("日本語")
      expect(budget.metadata[:sources].last).to include(original_characters: 4, retained_characters: 3)
    end

    it "records path-specific chunk rejection" do
      budget = Maglev::SnapshotBudget.new

      budget.record_chunk_truncation(original: 7, retained: 3)

      expect(budget.metadata[:sources]).to include(
        kind: :chunks,
        path: "snapshot.chunks",
        original_chunks: 7,
        retained_chunks: 3
      )
    end
  end
end
