# frozen_string_literal: true

require "spec_helper"
require "maglev/source_extractor"

RSpec.describe Maglev::SourceExtractor do
  it "assigns stable identities and types to registered knowledge sources" do
    fragments = described_class.new.call(<<~TEXT)
      Product#7
      name: Battery
      rich_text.notes.text: Handle carefully
      manuals[blob:42].text: Warranty
      reviews[0] Review#9
      reviews[0].body: Excellent
    TEXT

    expect(fragments.map { |item| [item.identity, item.type] }).to eq([
      ["name", :attribute], ["rich_text.notes.text", :rich_text],
      ["manuals[blob:42].text", :attachment], ["related:Review:9:body", :related_record]
    ])
  end
end
