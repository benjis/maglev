# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Dummy e-commerce domain" do
  it "loads the complete Greenhouse model graph" do
    expect([
      Category,
      Comment,
      Customer,
      CustomerProfile,
      CustomerTag,
      Inventory,
      Order,
      OrderItem,
      Product,
      ProductCategory,
      ProductVariant,
      Review,
      Tag,
      Tagging
    ].map(&:name)).to contain_exactly(
      "Category",
      "Comment",
      "Customer",
      "CustomerProfile",
      "CustomerTag",
      "Inventory",
      "Order",
      "OrderItem",
      "Product",
      "ProductCategory",
      "ProductVariant",
      "Review",
      "Tag",
      "Tagging"
    )
  end

  it "preserves the relationships used to exercise Maglev object graphs" do
    expect(Customer.reflect_on_association(:profile).macro).to eq(:has_one)
    expect(Product.reflect_on_association(:categories).options[:through]).to eq(:product_categories)
    expect(Comment.reflect_on_association(:commentable).options[:polymorphic]).to be(true)
    expect(Product.reflect_on_association(:images_attachments).macro).to eq(:has_many)
    expect(Product.reflect_on_association(:rich_text_description).macro).to eq(:has_one)
  end

  it "declares knowledge on business models without exposing join models" do
    expect(Product.maglev_config.exposed_attributes).to include("name", "sku", "price", "status")
    expect(Product.maglev_config.attached_sources.map(&:name)).to include("images")
    expect(Product.maglev_config.rich_text_sources.map(&:name)).to include("description")
    expect(ProductCategory.maglev_config).to be_nil
    expect(CustomerTag.maglev_config).to be_nil
  end

  it "builds a bounded snapshot from real cyclic ActiveRecord associations" do
    suffix = SecureRandom.hex(4)
    customer = Customer.create!(name: "Snapshot Customer", email: "snapshot-#{suffix}@example.test")
    product = Product.create!(name: "Snapshot Product", sku: "SNAP-#{suffix}", price: 25, status: "active")
    order = Order.create!(customer: customer, status: "pending", total: 25, placed_at: Time.zone.parse("2026-07-01 12:00:00"))
    OrderItem.create!(order: order, product: product, quantity: 1, unit_price: 25)

    snapshot = order.maglev_snapshot

    expect(snapshot).to include("status: pending")
    expect(snapshot).to include("customer.name: Snapshot Customer")
    expect(snapshot).to include("items[0].quantity: 1")
    expect(snapshot).not_to include("items[0].product.name")
  ensure
    OrderItem.where(order_id: order&.id).delete_all
    Order.where(id: order&.id).delete_all
    Product.where(id: product&.id).delete_all
    Customer.where(id: customer&.id).delete_all
  end
end
