# frozen_string_literal: true

require "spec_helper"
require "maglev/knowledge_config"
require "maglev/snapshot_builder"

ContentSnapshotBlob = Struct.new(:filename, :content_type, :byte_size, :content) do
  def download
    content
  end
end

class ContentSnapshotRecord
  attr_accessor :id, :name, :contracts, :notes

  def self.name = "ContentSnapshotRecord"
  def self.attribute_names = %w[id name]

  def self.maglev_config
    @maglev_config ||= Maglev::KnowledgeConfig.build(self) do
      expose :name
      expose_attached :contracts
      expose_rich_text :notes
    end
  end
end

class ContentSnapshotRichText
  def initialize(html)
    @html = html
  end

  def body
    self
  end

  def to_html
    @html
  end
end

RSpec.describe Maglev::SnapshotBuilder do
  around do |example|
    original = Maglev.configuration
    Maglev.instance_variable_set(:@configuration, Maglev::Configuration.new)
    example.run
  ensure
    Maglev.instance_variable_set(:@configuration, original)
  end

  it "includes attachment and rich-text knowledge with stable source labels" do
    record = ContentSnapshotRecord.new
    record.id = 5
    record.name = "Acme"
    record.contracts = [ContentSnapshotBlob.new("contract.txt", "text/plain", 13, "Renewal risk")]
    record.notes = ContentSnapshotRichText.new("<p>Important</p><script>alert('hidden')</script>")

    snapshot = described_class.new(record, ContentSnapshotRecord.maglev_config).build.to_s

    expect(snapshot).to include("contracts[blob:contract.txt].text: Renewal risk")
    expect(snapshot).to include("rich_text.notes.text: Important")
    expect(snapshot).not_to include("alert")
  end

  it "isolates attachment extraction failures without removing field content" do
    extractor = Class.new do
      def extract(_blob, source_name:)
        raise "broken #{source_name}"
      end
    end.new
    record = ContentSnapshotRecord.new
    record.id = 5
    record.name = "Acme"
    record.contracts = [ContentSnapshotBlob.new("contract.txt", "text/plain", 13, "Renewal risk")]

    snapshot = described_class.new(record, ContentSnapshotRecord.maglev_config, attachment_extractor: extractor).build.to_s

    expect(snapshot).to include("name: Acme")
    expect(snapshot).to include("contracts[blob:contract.txt].skipped: extraction_failed")
  end

  it "truncates attachment and rich-text sources through the builder with stable metadata paths" do
    Maglev.configuration.snapshot_attribute_max_characters = 5
    record = ContentSnapshotRecord.new
    record.id = 5
    record.name = "Acme"
    record.contracts = [ContentSnapshotBlob.new("contract.txt", "text/plain", 12, "Renewal risk")]
    record.notes = ContentSnapshotRichText.new("<p>Important note</p>")

    snapshot = described_class.new(record, ContentSnapshotRecord.maglev_config).build

    expect(snapshot.to_s).to include("contracts[blob:contract.txt].text: Renew")
    expect(snapshot.to_s).to include("rich_text.notes.text: Impor")
    expect(snapshot.metadata[:sources]).to include(
      include(kind: :attachment, path: "contracts[blob:contract.txt]", original_characters: 12, retained_characters: 5),
      include(kind: :rich_text, path: "rich_text.notes", original_characters: 14, retained_characters: 5)
    )
  end
end
