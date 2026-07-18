# frozen_string_literal: true

class Comment < ApplicationRecord
  belongs_to :customer, inverse_of: :comments
  belongs_to :commentable, polymorphic: true, inverse_of: :comments

  maglev_resource :comments do
    knowledge do
      expose :body
      tags :comment
      include_related :customer, depth: 1, limit: 1
    end
  end
end
