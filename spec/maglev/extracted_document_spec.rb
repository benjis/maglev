# frozen_string_literal: true

require "spec_helper"
require "maglev/extracted_document"

RSpec.describe Maglev::ExtractedDocument do
  it "represents extracted and skipped attachment content immutably" do
    extracted = described_class.extracted(
      source_identifier: "contracts[blob:1]",
      text: "Contract text",
      metadata: {filename: "contract.txt"}
    )
    skipped = described_class.skipped(
      source_identifier: "contracts[blob:2]",
      reason: "unsupported_content_type",
      metadata: {filename: "contract.pdf"}
    )

    expect(extracted).to be_extracted
    expect(extracted).not_to be_skipped
    expect(skipped).to be_skipped
    expect(skipped.text).to eq("")
    expect(skipped.metadata).to include(reason: "unsupported_content_type")
    expect(extracted).to be_frozen
  end
end
