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
end
