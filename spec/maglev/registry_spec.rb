# frozen_string_literal: true

require "rails_helper"

RSpec.describe Maglev::Registry do
  before do
    described_class.reset!
  end

  after do
    described_class.reset!
    Maglev::KnowledgeRegistry.rebuild!
  end

  it "registers immutable queryable and knowledge declarations separately" do
    model = Class.new(ApplicationRecord) do
      self.table_name = "products"
      has_many :variants, class_name: "ProductVariant", foreign_key: :product_id
      has_many_attached :images
      scope :priced_above, ->(amount) { where("price > ?", amount) }

      maglev_resource :catalog_products do
        description "Products available in the catalog"
        synonyms "catalog items", "merchandise"

        queryable do
          field :name, description: "Display name", synonyms: ["title"]
          field :status, enum: %w[active archived]
          prohibit :sku
          association :variants, resource: :catalog_variants
          scope :priced_above, parameters: {amount: {type: :decimal, required: true}}
          aggregates count: true, sum: [:price], average: [:price]
          limits rows: 50, operations: 8, joins: 2
          authorization :required
        end

        knowledge do
          expose :name
          expose_attached :images
        end
      end
    end

    entry = described_class.fetch(:catalog_products)

    expect(entry.model_class).to eq(model)
    expect(entry.description).to eq("Products available in the catalog")
    expect(entry.synonyms).to eq(["catalog items", "merchandise"])
    expect(entry.queryable.fields.map(&:name)).to eq(%w[name status])
    expect(entry.queryable.fields.last.enum_values).to eq(%w[active archived])
    expect(entry.queryable.prohibited_fields).to eq(["sku"])
    expect(entry.queryable.associations.first.resource).to eq("catalog_variants")
    expect(entry.queryable.scopes.first.parameters.fetch("amount").type).to eq(:decimal)
    expect(entry.queryable.aggregates.fetch(:sum)).to eq(["price"])
    expect(entry.queryable.limits).to eq({rows: 50, operations: 8, joins: 2})
    expect(entry.queryable.authorization).to eq(:required)
    expect(entry.knowledge.exposed_attributes).to eq(["name"])
    expect(entry.knowledge.attached_sources.map(&:name)).to eq(["images"])
    expect(entry).to be_frozen
    expect(entry.queryable.fields).to be_frozen
  end

  it "registers a knowledge-only resource without granting query access" do
    model = Class.new(ApplicationRecord) do
      self.table_name = "customers"

      def self.name = "KnowledgeOnlyRegistryCustomer"

      maglev_resource :knowledge_only_registry_customers do
        knowledge do
          expose :name
          hide :email
        end
      end
    end

    entry = described_class.fetch(:knowledge_only_registry_customers)

    expect(entry.model_class).to eq(model)
    expect(entry.queryable).to be_nil
    expect(entry.knowledge.exposed_attributes).to eq(["name"])
    expect(entry.knowledge.hidden_attributes).to eq(["email"])
  end

  it "rejects unknown fields, associations, scopes, aggregates, and attachments at registration" do
    model = Class.new(ApplicationRecord) do
      self.table_name = "products"
      has_many :variants, class_name: "ProductVariant", foreign_key: :product_id

      def self.name = "ClosedRegistryProduct"
    end

    expect do
      model.maglev_resource(:closed_products) { queryable { field :missing } }
    end.to raise_error(Maglev::ConfigurationError, /Unknown queryable field/)

    expect do
      model.maglev_resource(:closed_products) {
        queryable {
          field :name
          prohibit :name
        }
      }
    end.to raise_error(Maglev::ConfigurationError, /cannot be prohibited/)

    expect do
      model.maglev_resource(:closed_products) { queryable { association :missing, resource: :anything } }
    end.to raise_error(Maglev::ConfigurationError, /Unknown queryable association/)

    expect do
      model.maglev_resource(:closed_products) { queryable { scope :missing } }
    end.to raise_error(Maglev::ConfigurationError, /Unknown queryable scope/)

    expect do
      model.maglev_resource(:closed_products) { queryable { aggregates sum: [:missing] } }
    end.to raise_error(Maglev::ConfigurationError, /Unknown aggregate field/)

    expect do
      model.maglev_resource(:closed_products) { knowledge { expose_attached :missing } }
    end.to raise_error(Maglev::ConfigurationError, /Unknown attached knowledge source/)
  end

  it "rejects unsupported scope parameter types at registration" do
    model = Class.new(ActiveRecord::Base) do
      self.table_name = "registry_products"
      scope :priced_above, ->(amount) { where(price: amount..) }
    end
    stub_const("TypedRegistryProduct", model)

    expect do
      model.maglev_resource(:typed_registry_products) do
        queryable do
          scope :priced_above, parameters: {amount: {type: :number, required: true}}
        end
      end
    end.to raise_error(Maglev::ConfigurationError, /Unsupported scope parameter type number/)
  end
end
