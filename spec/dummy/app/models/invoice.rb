# frozen_string_literal: true

class Invoice < ApplicationRecord
  belongs_to :account, inverse_of: :invoices

  scope :due_before, ->(date) { where(due_on: ..date) }

  maglev_resource :invoices do
    description "Invoices scoped to one authorized account"

    queryable do
      field :status, enum: %w[draft open paid void]
      field :amount
      field :due_on
      field :paid_at
      prohibit :number, :internal_note
      association :account, resource: :accounts
      scope :due_before, parameters: {date: {type: :date, required: true}}
      aggregates count: true, sum: [:amount], average: [:amount]
      limits rows: 50, operations: 8, joins: 1
      authorization :required
    end

    knowledge do
      expose :status, :amount, :due_on, :paid_at
    end
  end
end
