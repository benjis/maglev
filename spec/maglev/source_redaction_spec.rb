# frozen_string_literal: true

require "spec_helper"
require "maglev/context_assembler"
require "maglev/search_result"

RedactionOwner = Struct.new(:id)

RSpec.describe "Source redaction" do
  around do |example|
    original = Maglev.configuration.source_redactor
    Maglev.configuration.source_redactor = ->(content, _source) { content.gsub(/\b\d{3}-\d{2}-\d{4}\b/, "[REDACTED]") }
    example.run
  ensure
    Maglev.configuration.source_redactor = original
  end

  it "redacts source content before context assembly output" do
    context = Maglev::ContextAssembler.new.assemble([
      Maglev::SearchResult.new(owner: RedactionOwner.new(1), content: "SSN 123-45-6789", source: "snapshot", distance: 0.1)
    ])

    expect(context.text).to include("[REDACTED]")
    expect(context.text).not_to include("123-45-6789")
    expect(context.sources.first[:content]).to include("[REDACTED]")
  end
end
