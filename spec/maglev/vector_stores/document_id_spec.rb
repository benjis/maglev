# frozen_string_literal: true

require "spec_helper"
require "maglev/vector_stores/document_id"

RSpec.describe Maglev::VectorStores::DocumentId do
  it "round trips the complete v0.3 resource, owner, source, and index identity" do
    id = described_class.build(
      resource_identifier: "admin_customers",
      owner_type: "Admin::Customer",
      owner_id: 42,
      source_identity: "related:Ticket:9:subject",
      chunk_index: 3,
      index_version: "v3-#{"a" * 64}"
    )

    expect(described_class.parse(id)).to eq([
      "admin_customers",
      "Admin::Customer",
      "42",
      "related:Ticket:9:subject",
      "3",
      "v3-#{"a" * 64}"
    ])
  end

  it "does not collide across resources, owners, sources, or index versions" do
    base = {
      resource_identifier: "customers",
      owner_type: "Customer",
      owner_id: 7,
      source_identity: "name",
      chunk_index: 0,
      index_version: "v3-#{"a" * 64}"
    }

    variants = [
      base.merge(resource_identifier: "accounts"),
      base.merge(owner_id: 8),
      base.merge(source_identity: "description"),
      base.merge(index_version: "v3-#{"b" * 64}")
    ]

    expect(variants.map { |attributes| described_class.build(**attributes) }).not_to include(
      described_class.build(**base)
    )
  end
end
