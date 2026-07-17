# frozen_string_literal: true

require "digest"
require "json"

require_relative "chunker"
require_relative "errors"

module Maglev
  class IndexIdentity
    PAYLOAD_NAMESPACE = "maglev-index"
    FORMAT_VERSION = 1

    def initialize(configuration:, adapter:, chunk_size:)
      @configuration = configuration
      @adapter = adapter
      @chunk_size = chunk_size
    end

    def to_s
      Digest::SHA256.hexdigest(JSON.generate([
        PAYLOAD_NAMESPACE,
        FORMAT_VERSION,
        required_string(@configuration.embedding_model, "embedding model"),
        positive_integer(@configuration.embedding_dimensions, "embedding dimensions"),
        adapter_id,
        adapter_version,
        required_string(Chunker::ALGORITHM_VERSION, "chunking algorithm version"),
        positive_integer(@chunk_size, "chunk size"),
        required_string(@configuration.application_index_version, "application index version")
      ]))
    end

    private

    def adapter_id
      value = @configuration.embedding_adapter_id
      if value.nil?
        unless @adapter.respond_to?(:maglev_adapter_id)
          raise ConfigurationError, "embedding adapter ID must be configured or implemented by the adapter"
        end
        value = @adapter.maglev_adapter_id
      end
      required_string(value, "embedding adapter ID")
    end

    def adapter_version
      value = @configuration.embedding_adapter_version
      if value.nil?
        unless @adapter.respond_to?(:maglev_adapter_version)
          raise ConfigurationError, "embedding adapter version must be configured or implemented by the adapter"
        end
        value = @adapter.maglev_adapter_version
      end
      required_string(value, "embedding adapter version")
    end

    def required_string(value, name)
      return value if value.is_a?(String) && !value.empty?

      raise ConfigurationError, "#{name} must be a non-empty string"
    end

    def positive_integer(value, name)
      return value if value.is_a?(Integer) && value.positive?

      raise ConfigurationError, "#{name} must be a positive integer"
    end
  end
end
