# frozen_string_literal: true

class CustomerTag < ApplicationRecord
  belongs_to :customer, inverse_of: :customer_tags
  belongs_to :tag, inverse_of: :customer_tags
end
