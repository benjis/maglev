# frozen_string_literal: true

class ProductVariant < ApplicationRecord
  belongs_to :product, inverse_of: :variants
  has_one :inventory, inverse_of: :product_variant, dependent: :destroy

  maglev_resource :product_variants do
    knowledge do
      expose :name, :sku, :price
      tags :product_variant
      include_related :inventory, depth: 1, limit: 1
    end
  end
end
