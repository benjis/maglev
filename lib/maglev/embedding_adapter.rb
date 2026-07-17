# frozen_string_literal: true

require_relative "errors"

module Maglev
  class EmbeddingAdapter
    def maglev_adapter_id
      raise ConfigurationError, "embedding adapter ID must be implemented by concrete adapters"
    end

    def maglev_adapter_version
      raise ConfigurationError, "embedding adapter version must be implemented by concrete adapters"
    end

    def embed(_text)
      raise NotImplementedError, "#{self.class.name} must implement #embed"
    end
  end
end
