# frozen_string_literal: true

class ProductCategory < ApplicationRecord
  belongs_to :product, inverse_of: :product_categories
  belongs_to :category, inverse_of: :product_categories
end
