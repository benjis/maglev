# frozen_string_literal: true

require "spec_helper"
require "maglev/attachment_extractor"

FakeAttachmentBlob = Struct.new(:filename, :content_type, :byte_size, :content) do
  def download
    content
  end
end

RSpec.describe Maglev::AttachmentExtractor do
  it "extracts text-native blobs deterministically" do
    blob = FakeAttachmentBlob.new("contract.md", "text/markdown", 21, "# Renewal\nAt risk")

    document = described_class.new.extract(blob, source_name: "contracts")

    expect(document).to be_extracted
    expect(document.source_identifier).to eq("contracts[blob:contract.md]")
    expect(document.text).to eq("# Renewal\nAt risk")
    expect(document.metadata).to include(filename: "contract.md", content_type: "text/markdown", strategy: "deterministic")
  end

  it "sanitizes HTML without executing or preserving scripts" do
    blob = FakeAttachmentBlob.new("notes.html", "text/html", 80, "<h1>Hello</h1><script>alert('x')</script><p>World</p>")

    document = described_class.new.extract(blob, source_name: "contracts")

    expect(document.text).to eq("Hello World")
  end

  it "skips disallowed MIME types and oversized blobs with status metadata" do
    unsupported = FakeAttachmentBlob.new("scan.pdf", "application/pdf", 10, "%PDF")
    oversized = FakeAttachmentBlob.new("large.txt", "text/plain", 11, "hello world")
    extractor = described_class.new(allowed_content_types: ["text/plain"], max_bytes: 10)

    expect(extractor.extract(unsupported, source_name: "contracts")).to be_skipped
    expect(extractor.extract(oversized, source_name: "contracts").metadata[:reason]).to eq("size_limit")
  end

  it "limits extracted text length" do
    blob = FakeAttachmentBlob.new("large.txt", "text/plain", 20, "abcdefghij")

    document = described_class.new(max_characters: 4).extract(blob, source_name: "contracts")

    expect(document.text).to eq("abcd")
    expect(document.metadata[:truncated]).to eq(true)
  end
end
