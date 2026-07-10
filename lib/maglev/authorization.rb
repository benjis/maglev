# frozen_string_literal: true

require_relative "configuration"
require_relative "errors"

module Maglev
  class Authorization
    def initialize(adapter: Maglev.configuration.authorization_adapter)
      @adapter = adapter
    end

    def configured?
      !@adapter.nil?
    end

    def scope(model:, user:)
      return model.all unless configured? && user

      @adapter.scope(model: model, user: user)
    end

    def authorize(record:, user:)
      return true unless configured? && user

      result = @adapter.authorize(record: record, user: user)
      raise AuthorizationError, "Maglev authorization denied #{record.class.name}##{record_id(record)}" if result == false

      true
    end

    def authorized?(record:, user:)
      authorize(record: record, user: user)
    rescue AuthorizationError
      false
    end

    private

    def record_id(record)
      record.respond_to?(:id) ? record.id : "unknown"
    end
  end
end
