# frozen_string_literal: true

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
    attr_accessor :embedding_adapter, :embedding_dimensions, :embedding_model, :chunk_size,
      :generation_adapter, :generation_model, :context_max_characters,
      :context_per_owner_characters, :explain_question, :max_relation_depth,
      :attachment_extractor, :attachment_allowed_content_types,
      :attachment_max_bytes, :attachment_max_characters, :authorization_adapter,
      :provider_max_attempts, :provider_timeout, :source_redactor, :logger,
      :vector_store

    def initialize
      @embedding_dimensions = 1536
      @embedding_model = "text-embedding-3-small"
      @chunk_size = 1000
      @generation_model = "gpt-4.1-mini"
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
  end
end
