# frozen_string_literal: true

require "rails_helper"

RSpec.describe "registered association graph" do
  before do
    Maglev::Registry.reset!
  end

  after do
    Maglev::Registry.reset!
    Maglev::KnowledgeRegistry.rebuild!
  end

  def define_resource_class(name, table_name:, &block)
    klass = Class.new(ApplicationRecord)
    klass.table_name = table_name
    stub_const(name, klass)
    klass.class_eval(&block) if block
    klass
  end

  it "reflects one-to-one, one-to-many, and many-to-many edges without relationship redeclaration" do
    define_resource_class("AssociationGraphProfile", table_name: "customer_profiles") do
      belongs_to :customer, class_name: "AssociationGraphCustomer", foreign_key: :customer_id
      maglev_resource(:association_graph_profiles) { queryable { authorization :public } }
    end
    define_resource_class("AssociationGraphTag", table_name: "tags") do
      has_many :taggings, class_name: "AssociationGraphTagging", foreign_key: :tag_id
      has_many :customers, through: :taggings, source: :customer
      maglev_resource(:association_graph_tags) { queryable { authorization :public } }
    end
    define_resource_class("AssociationGraphTagging", table_name: "customer_tags") do
      belongs_to :customer, class_name: "AssociationGraphCustomer", foreign_key: :customer_id
      belongs_to :tag, class_name: "AssociationGraphTag", foreign_key: :tag_id
      maglev_resource(:association_graph_taggings) { queryable { authorization :public } }
    end
    define_resource_class("AssociationGraphCustomer", table_name: "customers") do
      has_one :profile, class_name: "AssociationGraphProfile", foreign_key: :customer_id
      has_many :taggings, class_name: "AssociationGraphTagging", foreign_key: :customer_id
      has_many :tags, through: :taggings, source: :tag
      maglev_resource(:association_graph_customers) { queryable { authorization :public } }
    end

    snapshot = Maglev::Registry.snapshot(
      resources: %i[
        association_graph_customers association_graph_profiles
        association_graph_taggings association_graph_tags
      ]
    )
    customer = snapshot.resources.find { |resource| resource.identifier == "association_graph_customers" }
    profile = snapshot.resources.find { |resource| resource.identifier == "association_graph_profiles" }

    expect(customer.associations.map { |association| [association.name, association.resource, association.macro, association.cardinality] }).to eq(
      [
        ["profile", "association_graph_profiles", :has_one, :one],
        ["taggings", "association_graph_taggings", :has_many, :many],
        ["tags", "association_graph_tags", :has_many, :many]
      ]
    )
    expect(profile.associations.first).to have_attributes(
      name: "customer",
      resource: "association_graph_customers",
      macro: :belongs_to,
      cardinality: :one
    )
  end

  it "narrows associations independently with allowlist and blocklist policy, with blocks taking precedence" do
    define_resource_class("AssociationPolicyTag", table_name: "tags") do
      maglev_resource(:association_policy_tags) { queryable { authorization :public } }
    end
    define_resource_class("AssociationPolicyTagging", table_name: "customer_tags") do
      belongs_to :tag, class_name: "AssociationPolicyTag", foreign_key: :tag_id
      maglev_resource(:association_policy_taggings) { queryable { authorization :public } }
    end
    customer = define_resource_class("AssociationPolicyCustomer", table_name: "customers") do
      has_many :taggings, class_name: "AssociationPolicyTagging", foreign_key: :customer_id
      has_many :tags, through: :taggings, source: :tag
      maglev_resource :association_policy_customers do
        queryable do
          association :taggings
          association :tags
          prohibit_association :taggings
          authorization :public
        end
      end
    end

    resource = Maglev::Registry.snapshot(
      resources: %i[association_policy_customers association_policy_taggings association_policy_tags]
    ).resources.find { |item| item.identifier == "association_policy_customers" }

    expect(resource.associations.map(&:name)).to eq(["tags"])
    expect(Maglev::Registry.fetch(:association_policy_customers).queryable.fields.map(&:name))
      .to eq(customer.columns_hash.keys.sort)
  end

  it "requires an explicit registered target restriction for polymorphic associations" do
    define_resource_class("AssociationGraphComment", table_name: "comments") do
      belongs_to :commentable, polymorphic: true
      maglev_resource(:association_graph_comments) { queryable { authorization :public } }
    end
    define_resource_class("AssociationGraphOrder", table_name: "orders") do
      maglev_resource(:association_graph_orders) { queryable { authorization :public } }
    end

    expect do
      Maglev::Registry.snapshot(resources: %i[association_graph_comments association_graph_orders])
    end.to raise_error(
      Maglev::ConfigurationError,
      "Polymorphic association AssociationGraphComment.commentable requires an explicit target resource"
    )
  end

  it "accepts a polymorphic association restricted to a compatible registered target" do
    define_resource_class("RestrictedAssociationOrder", table_name: "orders") do
      maglev_resource(:restricted_association_orders) { queryable { authorization :public } }
    end
    define_resource_class("RestrictedAssociationComment", table_name: "comments") do
      belongs_to :commentable, polymorphic: true
      maglev_resource :restricted_association_comments do
        queryable do
          association :commentable, resource: :restricted_association_orders
          authorization :public
        end
      end
    end

    comment = Maglev::Registry.snapshot(
      resources: %i[restricted_association_comments restricted_association_orders]
    ).resources.find { |resource| resource.identifier == "restricted_association_comments" }

    expect(comment.associations.first).to have_attributes(
      name: "commentable",
      resource: "restricted_association_orders",
      macro: :belongs_to,
      cardinality: :one,
      polymorphic: true
    )
  end

  it "rejects an explicit target restriction that is not a registered resource" do
    define_resource_class("InvalidTargetAssociationComment", table_name: "comments") do
      belongs_to :commentable, polymorphic: true
      maglev_resource :invalid_target_association_comments do
        queryable do
          association :commentable, resource: :misspelled_orders
          authorization :public
        end
      end
    end

    expect do
      Maglev::Registry.snapshot(resources: [:invalid_target_association_comments])
    end.to raise_error(
      Maglev::ConfigurationError,
      "Association InvalidTargetAssociationComment.commentable references unregistered resource misspelled_orders"
    )
  end

  it "annotates a reflected association without granting or narrowing authority" do
    define_resource_class("AnnotatedAssociationOrder", table_name: "orders") do
      maglev_resource(:annotated_association_orders) { queryable { authorization :public } }
    end
    define_resource_class("AnnotatedAssociationCustomer", table_name: "customers") do
      has_many :orders, class_name: "AnnotatedAssociationOrder", foreign_key: :customer_id
      maglev_resource :annotated_association_customers do
        queryable do
          annotate_association :orders, description: "Purchases placed by this customer", synonyms: ["purchases"]
          authorization :public
        end
      end
    end

    resource = Maglev::Registry.snapshot(
      resources: %i[annotated_association_customers annotated_association_orders]
    ).resources.find { |item| item.identifier == "annotated_association_customers" }

    expect(resource.associations.first).to have_attributes(
      name: "orders",
      description: "Purchases placed by this customer",
      synonyms: ["purchases"]
    )
  end

  it "omits reflected edges unless both endpoint resources are registered and authorized" do
    define_resource_class("UnavailableAssociationOrder", table_name: "orders") do
      maglev_resource(:unavailable_association_orders) { queryable { authorization :required } }
    end
    define_resource_class("UnavailableAssociationCustomer", table_name: "customers") do
      has_many :orders, class_name: "UnavailableAssociationOrder", foreign_key: :customer_id
      maglev_resource(:unavailable_association_customers) { queryable { authorization :public } }
    end

    resource = Maglev::Registry.snapshot(
      resources: %i[unavailable_association_customers unavailable_association_orders]
    ).resources.fetch(0)

    expect(resource.identifier).to eq("unavailable_association_customers")
    expect(resource.associations).to be_empty
  end

  it "omits a reflected edge when its target model is not registered" do
    define_resource_class("UnregisteredAssociationOrder", table_name: "orders")
    define_resource_class("RegisteredAssociationCustomer", table_name: "customers") do
      has_many :orders, class_name: "UnregisteredAssociationOrder", foreign_key: :customer_id
      maglev_resource(:registered_association_customers) { queryable { authorization :public } }
    end

    resource = Maglev::Registry.snapshot(resources: [:registered_association_customers]).resources.fetch(0)

    expect(resource.associations).to be_empty
  end

  it "resolves an inferred association to the exact registered STI resource" do
    base = define_resource_class("AssociationGraphProduct", table_name: "products") do
      maglev_resource(:association_graph_products) { queryable { authorization :public } }
    end
    special = Class.new(base)
    stub_const("AssociationGraphFeaturedProduct", special)
    special.maglev_resource(:association_graph_featured_products) { queryable { authorization :public } }
    define_resource_class("AssociationGraphLineItem", table_name: "order_items") do
      belongs_to :product, class_name: "AssociationGraphFeaturedProduct", foreign_key: :product_id
      maglev_resource(:association_graph_line_items) { queryable { authorization :public } }
    end

    line_item = Maglev::Registry.snapshot(
      resources: %i[
        association_graph_featured_products association_graph_line_items association_graph_products
      ]
    ).resources.find { |resource| resource.identifier == "association_graph_line_items" }

    expect(line_item.associations.first.resource).to eq("association_graph_featured_products")
  end

  it "fails closed with an actionable diagnostic when a reflected target cannot be resolved" do
    define_resource_class("UnresolvedAssociationCustomer", table_name: "customers") do
      has_many :orders, class_name: "MissingAssociationOrder", foreign_key: :customer_id
      maglev_resource(:unresolved_association_customers) { queryable { authorization :public } }
    end

    expect do
      Maglev::Registry.snapshot(resources: [:unresolved_association_customers])
    end.to raise_error(
      Maglev::ConfigurationError,
      /Cannot resolve association UnresolvedAssociationCustomer\.orders:/
    )
  end
end
