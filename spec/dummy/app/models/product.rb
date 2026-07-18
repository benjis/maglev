# frozen_string_literal: true

class Product < ApplicationRecord
  has_many :variants, class_name: "ProductVariant", inverse_of: :product, dependent: :destroy
  has_many :product_categories, inverse_of: :product, dependent: :destroy
  has_many :categories, through: :product_categories
  has_many :taggings, as: :taggable, dependent: :destroy
  has_many :tags, through: :taggings
  has_many :order_items, inverse_of: :product, dependent: :destroy
  has_many :reviews, inverse_of: :product, dependent: :destroy
  has_many :comments, as: :commentable, dependent: :destroy
  has_many_attached :images
  has_rich_text :description

  maglev_resource :products do
    knowledge do
      expose :name, :sku, :price, :status
      tags :product
      include_related :categories, depth: 1, limit: 10, inverse: :products
      include_related :variants, depth: 1, limit: 10
      include_related :reviews, depth: 1, limit: 10
      include_related :tags, depth: 1, limit: 5, inverse: :products
      expose_attached :images
      expose_rich_text :description
    end
  end
end
