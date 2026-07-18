# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Maglev ActiveRecord extension" do
  before do
    stub_const("KnowledgeCustomer", Class.new(ActiveRecord::Base) do
      def self.attribute_names
        %w[id name industry description internal_note]
      end

      attr_accessor :id, :name, :industry, :description, :internal_note
    end)
  end

  it "makes has_knowledge available through the Railtie" do
    KnowledgeCustomer.has_knowledge do
      expose :name, :industry, :description
      hide :internal_note
      tags :customer, :commercial
    end

    customer = KnowledgeCustomer.allocate
    customer.id = 123
    customer.name = "Acme Pty Ltd"
    customer.industry = "Retail"
    customer.description = nil
    customer.internal_note = "sensitive"

    expect(KnowledgeCustomer.maglev_config.exposed_attributes).to eq(%w[name industry description])
    expect(customer.maglev_snapshot).to eq(<<~TEXT.chomp)
      KnowledgeCustomer#123
      name: Acme Pty Ltd
      industry: Retail
      tags: customer, commercial
    TEXT
  end

  it "does not let inherited configuration mutate the parent model" do
    KnowledgeCustomer.has_knowledge do
      expose :name
      tags :parent
    end

    stub_const("EnterpriseKnowledgeCustomer", Class.new(KnowledgeCustomer) do
      def self.attribute_names
        %w[id name industry description internal_note]
      end
    end)

    EnterpriseKnowledgeCustomer.has_knowledge do
      expose :industry
      tags :child
    end

    expect(KnowledgeCustomer.maglev_config.exposed_attributes).to eq(["name"])
    expect(KnowledgeCustomer.maglev_config.tags).to eq(["parent"])
    expect(EnterpriseKnowledgeCustomer.maglev_config.exposed_attributes).to eq(["industry"])
    expect(EnterpriseKnowledgeCustomer.maglev_config.tags).to eq(["child"])
  end

  it "overwrites configuration on repeated declarations without adding callbacks" do
    callback_count_before = KnowledgeCustomer._save_callbacks.count

    KnowledgeCustomer.has_knowledge do
      expose :name
    end
    KnowledgeCustomer.has_knowledge do
      expose :industry
    end

    expect(KnowledgeCustomer.maglev_config.exposed_attributes).to eq(["industry"])
    expect(KnowledgeCustomer._save_callbacks.count).to eq(callback_count_before)
  end

  it "exposes immutable snapshot budget metadata without provider calls" do
    Maglev.configuration.snapshot_attribute_max_characters = 3
    Maglev.configuration.chunk_size = 5
    Maglev.configuration.snapshot_max_chunks = 1
    KnowledgeCustomer.has_knowledge { expose :name }
    customer = KnowledgeCustomer.allocate
    customer.id = 1
    customer.name = "long name"

    result = customer.maglev_snapshot_result
    preview = customer.maglev_context_preview

    expect(result.metadata[:truncated]).to be(true)
    expect(preview.metadata).to include(provider_calls: 0, truncated: true)
    expect(result.metadata[:sources]).to include(
      include(kind: :chunks, path: "snapshot.chunks", original_chunks: be > 1, retained_chunks: 1)
    )
  ensure
    Maglev.configuration.snapshot_attribute_max_characters = 20_000
    Maglev.configuration.chunk_size = 1_500
    Maglev.configuration.snapshot_max_chunks = 100
  end
end
