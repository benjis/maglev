# frozen_string_literal: true

require "active_support/notifications"

require_relative "configuration"
require_relative "errors"

module Maglev
  class ProviderCall
    def initialize(max_attempts: Maglev.configuration.provider_max_attempts)
      @max_attempts = max_attempts
    end

    def call(operation:)
      attempt = 0

      begin
        attempt += 1
        yield
      rescue RetryableProviderError => error
        raise if attempt >= @max_attempts

        ActiveSupport::Notifications.instrument(
          "maglev.provider.retry",
          operation: operation,
          attempt: attempt,
          error_class: error.class.name
        )
        retry
      rescue PermanentProviderError
        raise
      rescue Timeout::Error => error
        raise RetryableProviderError, error.message
      end
    end
  end
end
