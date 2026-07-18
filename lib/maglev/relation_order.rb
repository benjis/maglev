# frozen_string_literal: true

module Maglev
  module RelationOrder
    module_function

    def with_primary_key(order, model_class)
      return nil unless order

      normalized = order.dup
      primary_key = model_class.primary_key&.to_sym
      normalized[primary_key] = :asc if primary_key && !normalized.key?(primary_key)
      normalized.freeze
    end
  end
end
