# frozen_string_literal: true

class Account < ApplicationRecord
  has_many :invoices, inverse_of: :account, dependent: :destroy
  has_many :support_tickets, inverse_of: :account, dependent: :destroy

  maglev_resource :accounts do
    description "Tenant accounts in the billing and support reference domain"

    queryable do
      field :name
      association :invoices, resource: :invoices
      association :support_tickets, resource: :support_tickets
      limits rows: 50, operations: 8, joins: 2
      authorization :required
    end
  end
end
