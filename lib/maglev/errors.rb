# frozen_string_literal: true

module Maglev
  class Error < StandardError
  end

  class ConfigurationError < Error
  end

  class AuthorizationError < Error
  end

  class ProviderError < Error
  end

  class RetryableProviderError < ProviderError
  end

  class PermanentProviderError < ProviderError
  end
end
