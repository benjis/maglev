# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Maglev ActiveRecord extension" do
  before do
    stub_const("KnowledgeCustomer", Class.new(ActiveRecord::Base) do
      self.table_name = "customers"

      def self.attribute_names
        %w[id name industry description internal_note]
      end

      attr_accessor :id, :name, :industry, :description, :internal_note
    end)
  end

  it "configures knowledge only through the unified resource DSL" do
    expect(KnowledgeCustomer).not_to respond_to(:has_knowledge)

    KnowledgeCustomer.maglev_resource :knowledge_customers do
      knowledge do
        expose :name, :industry, :description
        hide :internal_note
        tags :customer, :commercial
      end
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
    KnowledgeCustomer.maglev_resource(:knowledge_customers) do
      knowledge do
        expose :name
        tags :parent
      end
    end

    stub_const("EnterpriseKnowledgeCustomer", Class.new(KnowledgeCustomer) do
      def self.attribute_names
        %w[id name industry description internal_note]
      end
    end)

    EnterpriseKnowledgeCustomer.maglev_resource(:enterprise_knowledge_customers) do
      knowledge do
        expose :industry
        tags :child
      end
    end

    expect(KnowledgeCustomer.maglev_config.exposed_attributes).to eq(["name"])
    expect(KnowledgeCustomer.maglev_config.tags).to eq(["parent"])
    expect(EnterpriseKnowledgeCustomer.maglev_config.exposed_attributes).to eq(["industry"])
    expect(EnterpriseKnowledgeCustomer.maglev_config.tags).to eq(["child"])
  end

  it "overwrites configuration on repeated declarations without adding callbacks" do
    callback_count_before = KnowledgeCustomer._save_callbacks.count

    KnowledgeCustomer.maglev_resource(:knowledge_customers) do
      knowledge do
        expose :name
      end
    end
    KnowledgeCustomer.maglev_resource(:knowledge_customers) do
      knowledge do
        expose :industry
      end
    end

    expect(KnowledgeCustomer.maglev_config.exposed_attributes).to eq(["industry"])
    expect(KnowledgeCustomer._save_callbacks.count).to eq(callback_count_before)
  end

  it "rejects RAG APIs when the resource does not declare knowledge" do
    KnowledgeCustomer.maglev_resource :query_only_customers do
      queryable do
        field :name
        authorization :public
      end
    end
    customer = KnowledgeCustomer.new(name: "Acme")

    expect { KnowledgeCustomer.search("Acme") }.to raise_error(Maglev::ConfigurationError, /declare maglev_resource knowledge/)
    expect { KnowledgeCustomer.retrieve("Acme") }.to raise_error(Maglev::ConfigurationError, /declare maglev_resource knowledge/)
    expect { KnowledgeCustomer.ask("Who is Acme?") }.to raise_error(Maglev::ConfigurationError, /declare maglev_resource knowledge/)
    expect { customer.maglev_snapshot }.to raise_error(Maglev::ConfigurationError, /declare maglev_resource knowledge/)
    expect { customer.ask("Who is Acme?") }.to raise_error(Maglev::ConfigurationError, /declare maglev_resource knowledge/)
  end

  it "removes RAG configuration and callbacks when knowledge is withdrawn" do
    KnowledgeCustomer.maglev_resource :reconfigured_customers do
      knowledge { expose :name }
    end

    KnowledgeCustomer.maglev_resource :reconfigured_customers do
      queryable do
        field :name
        authorization :public
      end
    end

    expect(KnowledgeCustomer.maglev_config).to be_nil
    expect(Maglev::Registry.fetch(:reconfigured_customers).knowledge).to be_nil
    expect(KnowledgeCustomer._commit_callbacks.map(&:filter)).not_to include(:maglev_reindex, :maglev_unindex)
  end

  it "exposes immutable snapshot budget metadata without provider calls" do
    Maglev.configuration.snapshot_attribute_max_characters = 3
    Maglev.configuration.chunk_size = 5
    Maglev.configuration.snapshot_max_chunks = 1
    KnowledgeCustomer.maglev_resource(:knowledge_customers) do
      knowledge { expose :name }
    end
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

  it "shares the unified result envelope across model and base-relation entry points" do
    KnowledgeCustomer.maglev_resource(:knowledge_customers) do
      knowledge { expose :name }
    end
    classifier = Class.new do
      def classify(**) = raise("explicit routing must not classify")
    end.new
    router = Maglev::Router.new(classifier: classifier)

    expect do
      KnowledgeCustomer.maglev_request("combine data and evidence", mode: :hybrid, router: router)
    end.to raise_error(Maglev::ConfigurationError, /fixed hybrid plan/)
    expect do
      KnowledgeCustomer.where(id: 123).maglev_request("combine data and evidence",
        mode: :hybrid, router: router)
    end.to raise_error(Maglev::ConfigurationError, /fixed hybrid plan/)
  end
end
