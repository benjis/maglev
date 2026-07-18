# frozen_string_literal: true

require "rails_helper"

RSpec.describe Maglev::SchemaSnapshot do
  before do
    Maglev::Registry.reset!
  end

  after do
    Maglev::Registry.reset!
    Maglev::KnowledgeRegistry.rebuild!
  end

  def define_resource_class(name, superclass: ApplicationRecord, table_name: "products", primary_key: nil, &block)
    klass = Class.new(superclass)
    klass.table_name = table_name
    klass.primary_key = primary_key if primary_key
    stub_const(name, klass)
    klass.class_eval(&block) if block
    klass
  end

  it "contains only request-authorized registered metadata and no record values" do
    define_resource_class("SnapshotVariant", table_name: "product_variants") do
      maglev_resource :snapshot_variants do
        queryable do
          field :name
          authorization :required
        end
      end
    end

    define_resource_class("SnapshotProduct") do
      enum :status, {active: "active", archived: "archived"}
      has_many :variants, class_name: "SnapshotVariant", foreign_key: :product_id
      scope :priced_above, ->(amount) { where("price > ?", amount) }

      maglev_resource :snapshot_products do
        description "Catalog products"
        queryable do
          field :name
          field :status
          field :sku, sensitive: true
          prohibit :price
          association :variants, resource: :snapshot_variants
          scope :priced_above, parameters: {amount: {type: :decimal, required: true}}
          aggregates count: true
          authorization :required
        end
      end
    end

    snapshot = Maglev::Registry.snapshot(
      resources: %i[snapshot_products snapshot_variants missing],
      user: :reader,
      authorizer: ->(_entry, user) { user == :reader }
    )

    expect(snapshot.resources.map(&:identifier)).to eq(%w[snapshot_products snapshot_variants])
    resource = snapshot.resources.find { |item| item.identifier == "snapshot_products" }
    expect(resource.table_name).to eq("products")
    expect(resource.primary_key).to eq("id")
    expect(resource.fields.map { |field| [field.name, field.type, field.null] }).to include(
      ["name", :string, false], ["status", :string, false]
    )
    expect(resource.fields.map(&:name)).not_to include("sku", "price")
    expect(resource.fields.find { |field| field.name == "status" }.enum_values).to eq(%w[active archived])
    expect(resource.associations.first).to have_attributes(
      name: "variants", macro: :has_many, polymorphic: false, resource: "snapshot_variants"
    )
    expect(snapshot.to_h.to_s).not_to include("secret-product-value")
    expect(snapshot).to be_frozen
    expect(snapshot.to_h).to be_frozen
  end

  it "omits associations whose target resource is unregistered or unauthorized" do
    define_resource_class("ClosedAssociationProduct") do
      has_many :variants, class_name: "ProductVariant", foreign_key: :product_id

      maglev_resource :closed_association_products do
        queryable do
          field :name
          association :variants, resource: :private_variants
          authorization :public
        end
      end
    end

    define_resource_class("PrivateAssociationVariant", table_name: "product_variants") do
      maglev_resource :private_variants do
        queryable do
          field :name
          authorization :required
        end
      end
    end

    snapshot = Maglev::Registry.snapshot(resources: %i[closed_association_products private_variants])

    expect(snapshot.resources.map(&:identifier)).to eq(["closed_association_products"])
    expect(snapshot.resources.first.associations).to be_empty
    expect(snapshot.paths).to be_empty
  end

  it "rejects a registered association resource that does not match its reflection model" do
    define_resource_class("MismatchedAssociationProduct") do
      has_many :variants, class_name: "ProductVariant", foreign_key: :product_id

      maglev_resource :mismatched_association_products do
        queryable do
          field :name
          association :variants, resource: :unrelated_tags
          authorization :public
        end
      end
    end
    define_resource_class("UnrelatedAssociationTag", table_name: "tags") do
      maglev_resource :unrelated_tags do
        queryable do
          field :name
          authorization :public
        end
      end
    end

    expect do
      Maglev::Registry.snapshot(resources: %i[mismatched_association_products unrelated_tags])
    end.to raise_error(Maglev::ConfigurationError, /does not match resource/)
  end

  it "fails closed when required authorization has no authorizer" do
    define_resource_class("PrivateSnapshotProduct") do
      maglev_resource :private_snapshot_products do
        queryable do
          field :name
          authorization :required
        end
      end
    end

    expect(Maglev::Registry.snapshot(resources: [:private_snapshot_products]).resources).to be_empty
  end

  it "reports custom table names, primary keys, STI, polymorphism, and two-hop registrations deterministically" do
    base = define_resource_class("SnapshotCatalogItem", table_name: "products", primary_key: "sku") do
      self.inheritance_column = "status"
      has_many :taggings, as: :taggable, class_name: "SnapshotTagging"

      maglev_resource :catalog_items do
        queryable do
          field :sku
          association :taggings, resource: :snapshot_taggings
          authorization :public
        end
      end
    end
    define_resource_class("SnapshotSpecialItem", superclass: base, table_name: "products") do
      maglev_resource :special_items do
        queryable do
          field :sku
          authorization :public
        end
      end
    end

    define_resource_class("SnapshotTagging", table_name: "taggings") do
      belongs_to :taggable, polymorphic: true
      belongs_to :tag, class_name: "SnapshotTag"

      maglev_resource :snapshot_taggings do
        queryable do
          field :tag_id
          association :taggable, resource: :catalog_items
          association :tag, resource: :snapshot_tags
          authorization :public
        end
      end
    end

    define_resource_class("SnapshotTag", table_name: "tags") do
      maglev_resource :snapshot_tags do
        queryable do
          field :name
          authorization :public
        end
      end
    end

    first = Maglev::Registry.snapshot(resources: %i[snapshot_taggings catalog_items snapshot_tags special_items])
    second = Maglev::Registry.snapshot(resources: %i[special_items snapshot_tags catalog_items snapshot_taggings])

    expect(first.to_h).to eq(second.to_h)
    item = first.resources.find { |resource| resource.identifier == "catalog_items" }
    tagging = first.resources.find { |resource| resource.identifier == "snapshot_taggings" }
    special = first.resources.find { |resource| resource.identifier == "special_items" }
    expect(item).to have_attributes(table_name: "products", primary_key: "sku", sti_base: "catalog_items", inheritance_column: "status")
    expect(special).to have_attributes(sti_base: "catalog_items", inheritance_column: "status")
    expect(tagging.associations.find { |association| association.name == "taggable" }.polymorphic).to be(true)
    expect(first.paths).to include("catalog_items.taggings.tag")
  end

  it "bounds resources, fields, associations, and serialized bytes" do
    define_resource_class("BoundedSnapshotProduct") do
      maglev_resource :bounded_snapshot_products do
        queryable do
          field :id
          field :name
          field :sku
          authorization :public
        end
      end
    end

    snapshot = Maglev::Registry.snapshot(
      resources: [:bounded_snapshot_products],
      limits: {resources: 1, fields: 2, associations: 0, bytes: 2_000}
    )

    expect(snapshot.resources.size).to eq(1)
    expect(snapshot.resources.first.fields.map(&:name)).to eq(%w[id name])
    expect(snapshot.to_json.bytesize).to be <= 2_000

    expect do
      Maglev::Registry.snapshot(resources: [:bounded_snapshot_products], limits: {bytes: 20})
    end.to raise_error(Maglev::ConfigurationError, /schema snapshot exceeds/)

    globally_bounded = Maglev::Registry.snapshot(
      resources: [:bounded_snapshot_products],
      limits: {resources: 100, fields: 100, associations: 100, bytes: 100_000}
    )
    expect(globally_bounded.resources.first.fields.size).to eq(3)

    expect do
      Maglev::Registry.snapshot(resources: [:bounded_snapshot_products], limits: {fields: -1})
    end.to raise_error(Maglev::ConfigurationError, /snapshot limits/)
  end

  it "does not retain associations to resources removed by the resource bound" do
    define_resource_class("AResourceBoundProduct") do
      has_many :variants, class_name: "ZResourceBoundVariant", foreign_key: :product_id

      maglev_resource :a_resource_bound_products do
        queryable do
          field :name
          association :variants, resource: :z_resource_bound_variants
          authorization :public
        end
      end
    end
    define_resource_class("ZResourceBoundVariant", table_name: "product_variants") do
      maglev_resource :z_resource_bound_variants do
        queryable do
          field :name
          authorization :public
        end
      end
    end

    snapshot = Maglev::Registry.snapshot(
      resources: %i[a_resource_bound_products z_resource_bound_variants],
      limits: {resources: 1}
    )

    expect(snapshot.resources.map(&:identifier)).to eq(["a_resource_bound_products"])
    expect(snapshot.resources.first.associations).to be_empty
    expect(snapshot.paths).to be_empty
  end

  it "invalidates cached snapshots and rebuilds registrations after reload" do
    model = define_resource_class("ReloadableSnapshotProduct") do
      maglev_resource :reloadable_snapshot_products do
        queryable do
          field :name
          authorization :public
        end
      end
    end

    first = Maglev::Registry.snapshot(resources: [:reloadable_snapshot_products])
    expect(Maglev::Registry.snapshot(resources: [:reloadable_snapshot_products])).to equal(first)

    Maglev::Registry.invalidate!
    second = Maglev::Registry.snapshot(resources: [:reloadable_snapshot_products])
    expect(second).not_to equal(first)

    Maglev::Registry.reset!
    expect(Maglev::Registry.fetch(:reloadable_snapshot_products)).to be_nil
    Maglev::Registry.rebuild!
    expect(Maglev::Registry.fetch(:reloadable_snapshot_products).model_class).to eq(model)

    knowledge_only = define_resource_class("ReloadableKnowledgeProduct") do
      maglev_resource :reloadable_knowledge_products do
        knowledge { expose :name }
      end
    end
    Maglev::Registry.reset!
    Maglev::Registry.rebuild!
    expect(Maglev::Registry.fetch(:reloadable_knowledge_products).model_class).to eq(knowledge_only)

    combined = define_resource_class("ReloadableCombinedProduct") do
      maglev_resource :reloadable_combined_products do
        queryable do
          field :name
          authorization :public
        end
        knowledge { expose :name }
      end
    end
    Maglev::Registry.rebuild!
    expect(Maglev::Registry.fetch(:reloadable_combined_products).model_class).to eq(combined)

    replacement = Class.new(ApplicationRecord)
    replacement.table_name = "products"
    stub_const("ReloadableSnapshotProduct", replacement)
    Maglev::Registry.rebuild!
    expect(Maglev::Registry.fetch(:reloadable_snapshot_products)).to be_nil
  end
end
