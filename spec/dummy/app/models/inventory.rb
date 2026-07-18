# frozen_string_literal: true

class Inventory < ApplicationRecord
  belongs_to :product_variant, inverse_of: :inventory

  maglev_resource :inventories do
    knowledge do
      expose :quantity, :warehouse
      tags :inventory
    end
  end
end
