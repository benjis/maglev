# frozen_string_literal: true

class Review < ApplicationRecord
  belongs_to :customer, inverse_of: :reviews
  belongs_to :product, inverse_of: :reviews
  has_many :comments, as: :commentable, dependent: :destroy

  has_knowledge do
    expose :rating, :title, :body
    tags :review
    include_related :customer, depth: 1, limit: 1
    include_related :product, depth: 1, limit: 1
  end
end
