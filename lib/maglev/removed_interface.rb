# frozen_string_literal: true

module Maglev
  module RemovedInterface
    MISSING = Object.new.freeze

    MESSAGES = {
      request: "Maglev.request was removed in v0.3; use Maglev.ask(question, user:, context:) and inspect the BusinessOutcome",
      maglev_request: "maglev_request was removed in v0.3; use Maglev.ask(question, user:, context:) without a mode, resource, or base relation",
      record_ask: "record-level ask and explain were removed in v0.3; use Maglev.ask(question, user:, context:) or Maglev::Answerer for explicit low-level generation",
      model_ask: "model-level ask now uses the v0.3 BusinessOutcome contract; pass user: and context:, or use Maglev::Answerer for explicit low-level generation"
    }.freeze

    def self.raise!(name)
      raise ConfigurationError, MESSAGES.fetch(name)
    end
  end

  class << self
    def method_missing(name, ...)
      RemovedInterface.raise!(:request) if name == :request
      super
    end

    def respond_to_missing?(name, include_private = false)
      super
    end
  end
end
