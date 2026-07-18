# frozen_string_literal: true

class Category < ApplicationRecord
  has_many :product_categories, inverse_of: :category, dependent: :destroy
  has_many :products, through: :product_categories

  maglev_resource :categories do
    knowledge do
      expose :name, :description
      tags :category
    end
  end
end
