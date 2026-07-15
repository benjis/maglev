# frozen_string_literal: true

require "active_support"
require "active_support/notifications"
require "timeout"

require_relative "configuration"
require_relative "errors"

module Maglev
  class ProviderCall
    def initialize(max_attempts: Maglev.configuration.provider_max_attempts, timeout: Maglev.configuration.provider_timeout)
      @max_attempts = max_attempts
      @timeout = timeout
    end

    def call(operation:)
      attempt = 0

      begin
        attempt += 1
        Timeout.timeout(@timeout) { yield }
      rescue Timeout::Error => error
        retryable_error = RetryableProviderError.new(error.message)
        retryable_error.set_backtrace(error.backtrace)
        raise retryable_error if attempt >= @max_attempts

        instrument_retry(operation, attempt, retryable_error)
        retry
      rescue RetryableProviderError => error
        raise if attempt >= @max_attempts

        instrument_retry(operation, attempt, error)
        retry
      end
    end

    private

    def instrument_retry(operation, attempt, error)
      ActiveSupport::Notifications.instrument(
        "maglev.provider.retry",
        operation: operation,
        attempt: attempt,
        error_class: error.class.name
      )
    end
  end
end
