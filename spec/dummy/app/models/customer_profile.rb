# frozen_string_literal: true

class CustomerProfile < ApplicationRecord
  belongs_to :customer, inverse_of: :profile

  maglev_resource :customer_profiles do
    knowledge do
      expose :bio, :location
      tags :customer_profile
    end
  end
end
