# frozen_string_literal: true

class OrderItem < ApplicationRecord
  belongs_to :order, inverse_of: :items
  belongs_to :product, inverse_of: :order_items
  belongs_to :product_variant, optional: true

  has_knowledge do
    expose :quantity, :unit_price
    tags :order_item
    include_related :product, depth: 1, limit: 1
  end
end
