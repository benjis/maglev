# frozen_string_literal: true

class Order < ApplicationRecord
  belongs_to :customer, inverse_of: :orders
  has_many :items, class_name: "OrderItem", inverse_of: :order, dependent: :destroy
  has_many :comments, as: :commentable, dependent: :destroy

  has_knowledge do
    expose :status, :total, :placed_at
    tags :order
    include_related :customer, depth: 1, limit: 1
    include_related :items, depth: 1, limit: 20
  end
end
