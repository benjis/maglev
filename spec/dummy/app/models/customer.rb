# frozen_string_literal: true

class Customer < ApplicationRecord
  has_one :profile, class_name: "CustomerProfile", inverse_of: :customer, dependent: :destroy
  has_many :orders, inverse_of: :customer, dependent: :destroy
  has_many :reviews, inverse_of: :customer, dependent: :destroy
  has_many :comments, inverse_of: :customer, dependent: :destroy
  has_many :customer_tags, inverse_of: :customer, dependent: :destroy
  has_many :tags, through: :customer_tags
  has_one_attached :avatar

  maglev_resource :customers do
    knowledge do
      expose :name, :email, :created_at
      tags :customer
      include_related :profile, depth: 1, limit: 1
      include_related :orders, depth: 1, limit: 10
      include_related :reviews, depth: 1, limit: 10
      include_related :tags, depth: 1, limit: 5, inverse: :customers
      expose_attached :avatar
    end
  end
end
