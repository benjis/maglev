# frozen_string_literal: true

require "rails_helper"

RSpec.describe "reflection-first resource registration" do
  before do
    Maglev::Registry.reset!
  end

  after do
    Maglev::Registry.reset!
    Maglev::KnowledgeRegistry.rebuild!
  end

  it "infers a stable identifier and reflects physical columns and their types" do
    model = Class.new(ApplicationRecord) do
      self.table_name = "products"
    end
    stub_const("ReflectedProduct", model)

    model.maglev_resource

    entry = Maglev::Registry.fetch(:reflected_products)
    snapshot = Maglev::Registry.snapshot(resources: [:reflected_products], authorizer: ->(*) { true })
    fields = snapshot.resources.fetch(0).fields

    expect(entry.model_class).to eq(model)
    expect(fields.map(&:name)).to eq(model.columns_hash.keys.sort)
    expect(fields.to_h { |field| [field.name, field.type] }).to include(
      "name" => :string,
      "price" => :decimal,
      "created_at" => :datetime
    )
  end

  it "uses the complete namespaced model name when inferring identity" do
    namespace = Module.new
    stub_const("Billing", namespace)
    model = Class.new(ApplicationRecord) do
      self.table_name = "invoices"
    end
    stub_const("Billing::Invoice", model)

    model.maglev_resource

    expect(Maglev::Registry.fetch(:billing_invoices).model_class).to eq(model)
  end

  it "reflects enum definitions from Active Record" do
    model = Class.new(ApplicationRecord) do
      self.table_name = "products"
      enum :status, {draft: "draft", published: "published"}
    end
    stub_const("ReflectedPublication", model)

    model.maglev_resource

    snapshot = Maglev::Registry.snapshot(resources: [:reflected_publications], authorizer: ->(*) { true })
    status = snapshot.resources.fetch(0).fields.find { |field| field.name == "status" }
    expect(status.enum_values).to eq(%w[draft published])
  end

  it "replaces the same model registration deterministically" do
    model = Class.new(ApplicationRecord) do
      self.table_name = "products"
    end
    stub_const("RepeatedReflectedProduct", model)

    3.times { model.maglev_resource }

    expect(Maglev::Registry.entries.count { |entry| entry.identifier == "repeated_reflected_products" }).to eq(1)
    expect(Maglev::Registry.fetch(:repeated_reflected_products).queryable.fields.map(&:name)).to eq(model.columns_hash.keys.sort)
  end

  it "requires an explicit identifier when the model identity is ambiguous" do
    model = Class.new(ApplicationRecord) do
      self.table_name = "products"
    end

    expect { model.maglev_resource }.to raise_error(
      Maglev::ConfigurationError,
      /cannot infer.*identifier.*anonymous/i
    )
  end

  it "fails actionably when Active Record metadata cannot be reflected" do
    model = Class.new(ApplicationRecord) do
      self.table_name = "missing_reflection_table"
    end
    stub_const("MissingReflectionTable", model)

    expect { model.maglev_resource }.to raise_error(
      Maglev::ConfigurationError,
      /cannot reflect MissingReflectionTable.*missing_reflection_table.*does not exist/i
    )
  end
end
