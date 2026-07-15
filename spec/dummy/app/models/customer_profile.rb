# frozen_string_literal: true

class CustomerProfile < ApplicationRecord
  belongs_to :customer, inverse_of: :profile

  has_knowledge do
    expose :bio, :location
    tags :customer_profile
  end
end
