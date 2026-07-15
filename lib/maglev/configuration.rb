# frozen_string_literal: true

require_relative "provider_configuration"

module Maglev
  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield configuration
    end
  end

  class Configuration
    attr_accessor :embedding_adapter, :chunk_size,
      :generation_adapter, :context_max_characters,
      :context_per_owner_characters, :explain_question, :max_relation_depth,
      :attachment_extractor, :attachment_allowed_content_types,
      :attachment_max_bytes, :attachment_max_characters, :authorization_adapter,
      :provider_max_attempts, :provider_timeout, :source_redactor, :logger,
      :vector_store

    def initialize
      @embedding_provider = ProviderConfiguration.new(
        url: "https://api.openai.com/v1",
        model: "text-embedding-3-small",
        dimensions: 1536
      )
      @generation_provider = ProviderConfiguration.new(
        url: "https://api.openai.com/v1",
        model: "gpt-4.1-mini"
      )
      @chunk_size = 1000
      @context_max_characters = 4000
      @context_per_owner_characters = 1200
      @explain_question = "Explain what the available knowledge says about this record."
      @max_relation_depth = 3
      @attachment_allowed_content_types = ["text/plain", "text/markdown", "text/html", "application/xhtml+xml"]
      @attachment_max_bytes = 5 * 1024 * 1024
      @attachment_max_characters = 20_000
      @provider_max_attempts = 2
      @provider_timeout = 30
      @source_redactor = nil
    end

    def embedding_provider
      yield @embedding_provider if block_given?
      @embedding_provider
    end

    def generation_provider
      yield @generation_provider if block_given?
      @generation_provider
    end

    def embedding_model = @embedding_provider.model

    def embedding_model=(model)
      @embedding_provider.model = model
    end

    def embedding_dimensions = @embedding_provider.dimensions

    def embedding_dimensions=(dimensions)
      @embedding_provider.dimensions = dimensions
    end

    def generation_model = @generation_provider.model

    def generation_model=(model)
      @generation_provider.model = model
    end
  end
end
