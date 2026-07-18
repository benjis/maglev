# frozen_string_literal: true

class Tag < ApplicationRecord
  has_many :taggings, inverse_of: :tag, dependent: :destroy
  has_many :products, through: :taggings, source: :taggable, source_type: "Product"
  has_many :customer_tags, inverse_of: :tag, dependent: :destroy
  has_many :customers, through: :customer_tags

  maglev_resource :tags do
    knowledge do
      expose :name
      tags :tag
    end
  end
end
