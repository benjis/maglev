# frozen_string_literal: true

require "rails_helper"

RSpec.describe "structured field policy" do
  before do
    Maglev::Registry.reset!
  end

  after do
    Maglev::Registry.reset!
    Maglev::KnowledgeRegistry.rebuild!
  end

  it "keeps reflected fields open by default when queryable options are declared" do
    model = Class.new(ApplicationRecord) do
      self.table_name = "products"
    end
    stub_const("DefaultOpenPolicyProduct", model)

    model.maglev_resource do
      queryable do
        limits rows: 25
      end
    end

    entry = Maglev::Registry.fetch(:default_open_policy_products)

    expect(entry.queryable.fields.map(&:name)).to eq(model.columns_hash.keys.sort)
  end

  it "switches structured fields to allowlist mode when fields are allowed" do
    model = Class.new(ApplicationRecord) do
      self.table_name = "products"
    end
    stub_const("AllowlistedPolicyProduct", model)

    model.maglev_resource do
      queryable do
        field :name
        field :status
      end
    end

    entry = Maglev::Registry.fetch(:allowlisted_policy_products)

    expect(entry.queryable.fields.map(&:name)).to eq(%w[name status])
  end

  it "gives explicit field blocks precedence in default-open and allowlist modes" do
    default_open = Class.new(ApplicationRecord) do
      self.table_name = "products"
    end
    allowlisted = Class.new(ApplicationRecord) do
      self.table_name = "products"
    end
    stub_const("BlockedDefaultOpenPolicyProduct", default_open)
    stub_const("BlockedAllowlistedPolicyProduct", allowlisted)

    default_open.maglev_resource do
      queryable { prohibit :sku }
    end
    allowlisted.maglev_resource do
      queryable do
        field :name
        field :sku
        field :status
        prohibit :sku
      end
    end

    expect(Maglev::Registry.fetch(:blocked_default_open_policy_products).queryable.fields.map(&:name))
      .to eq(default_open.columns_hash.keys.sort - ["sku"])
    expect(Maglev::Registry.fetch(:blocked_allowlisted_policy_products).queryable.fields.map(&:name))
      .to eq(%w[name status])
  end

  it "annotates reflected fields without changing their authority" do
    model = Class.new(ApplicationRecord) do
      self.table_name = "products"
    end
    stub_const("AnnotatedPolicyProduct", model)

    model.maglev_resource do
      queryable do
        annotate_field :price, description: "Retail price in AUD", synonyms: ["unit price"]
      end
    end

    resource = Maglev::Registry.snapshot(
      resources: [:annotated_policy_products],
      authorizer: ->(*) { true }
    ).resources.fetch(0)
    price = resource.fields.find { |field| field.name == "price" }

    expect(resource.fields.map(&:name)).to eq(model.columns_hash.keys.sort)
    expect(price.description).to eq("Retail price in AUD")
    expect(price.synonyms).to eq(["unit price"])
  end

  it "rejects unknown field references and conflicting annotations actionably" do
    model = Class.new(ApplicationRecord) do
      self.table_name = "products"
      attribute :virtual_label, :string
    end
    stub_const("InvalidPolicyProduct", model)

    expect do
      model.maglev_resource { queryable { annotate_field :missing, description: "Unknown" } }
    end.to raise_error(
      Maglev::ConfigurationError,
      "Unknown annotated field InvalidPolicyProduct.missing"
    )

    expect do
      model.maglev_resource do
        queryable do
          annotate_field :price, description: "Retail price"
          annotate_field :price, description: "Wholesale price"
        end
      end
    end.to raise_error(
      Maglev::ConfigurationError,
      "Field annotation declared more than once for InvalidPolicyProduct.price"
    )

    expect do
      model.maglev_resource do
        queryable do
          field :price, description: "Retail price"
          annotate_field :price, description: "Wholesale price"
        end
      end
    end.to raise_error(
      Maglev::ConfigurationError,
      "Conflicting field annotation for InvalidPolicyProduct.price: description"
    )

    expect do
      model.maglev_resource { queryable { prohibit :virtual_label } }
    end.to raise_error(
      Maglev::ConfigurationError,
      "Unknown prohibited field InvalidPolicyProduct.virtual_label"
    )
  end

  it "keeps structured exposure independent from knowledge exposure" do
    model = Class.new(ApplicationRecord) do
      self.table_name = "products"
    end
    stub_const("IndependentKnowledgePolicyProduct", model)

    model.maglev_resource do
      queryable do
        field :name
        field :sku
        field :status
        field :price
        prohibit :sku, :price
      end
      knowledge do
        content :sku, :price
        context :status
        prohibit :price
      end
    end

    entry = Maglev::Registry.fetch(:independent_knowledge_policy_products)

    expect(entry.queryable.fields.map(&:name)).to eq(%w[name status])
    expect(entry.knowledge.content_attributes).to eq(["sku"])
    expect(entry.knowledge.context_attributes).to eq(["status"])
    expect(entry.knowledge.prohibited_attributes).to eq(["price"])
  end
end
