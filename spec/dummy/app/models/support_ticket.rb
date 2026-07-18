# frozen_string_literal: true

class SupportTicket < ApplicationRecord
  belongs_to :account, inverse_of: :support_tickets

  maglev_resource :support_tickets do
    description "Customer support tickets scoped to one authorized account"

    queryable do
      field :status, enum: %w[open pending resolved closed]
      field :priority, enum: %w[low normal high urgent]
      field :created_at
      prohibit :subject, :body, :private_note
      association :account, resource: :accounts
      limits rows: 50, operations: 8, joins: 1
      authorization :required
    end

    knowledge do
      expose :subject, :body, :status, :priority
    end
  end
end
