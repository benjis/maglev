# frozen_string_literal: true

require "spec_helper"
require "maglev/vector_stores/document_id"

RSpec.describe Maglev::VectorStores::DocumentId do
  it "round trips namespaced owners and source identities containing colons" do
    id = described_class.build(owner_type: "Admin::Customer", owner_id: 42,
      source_identity: "related:Ticket:9:subject", chunk_index: 3)

    expect(described_class.parse(id)).to eq(["Admin::Customer", "42", "related:Ticket:9:subject", "3"])
  end
end
