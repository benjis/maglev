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
      :vector_store, :embedding_adapter_id, :embedding_adapter_version,
      :application_index_version, :minimum_similarity,
      :snapshot_attribute_max_characters, :snapshot_related_record_max_characters,
      :snapshot_max_characters, :snapshot_max_chunks,
      :structured_query_role, :structured_query_executor_wrapper, :planner_adapter, :routing_adapter, :audit_sink,
      :tenant_id_resolver

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
      @application_index_version = "1"
      @minimum_similarity = nil
      @snapshot_attribute_max_characters = 20_000
      @snapshot_related_record_max_characters = 50_000
      @snapshot_max_characters = 100_000
      @snapshot_max_chunks = 100
      @structured_query_timeout = 5
      @structured_query_role = nil
      @structured_query_executor_wrapper = nil
      @structured_evidence_max_rows = 100
      @structured_evidence_max_bytes = 32_768
      @retrieval_max_candidates = 1_000
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

    def tenant_id(record: nil, user: nil)
      return unless @tenant_id_resolver

      value = @tenant_id_resolver.call(record: record, user: user)
      return if value.nil?
      raise ArgumentError, "tenant id must be a non-empty String" unless value.is_a?(String) && !value.empty?

      value
    end

    attr_reader :structured_query_timeout, :structured_evidence_max_rows, :structured_evidence_max_bytes,
      :retrieval_max_candidates

    def structured_query_timeout=(value)
      raise ArgumentError, "structured_query_timeout must be positive" unless value.is_a?(Numeric) && value.positive?

      @structured_query_timeout = value
    end

    %i[structured_evidence_max_rows structured_evidence_max_bytes].each do |name|
      define_method(:"#{name}=") do |value|
        raise ArgumentError, "#{name} must be a positive Integer" unless value.is_a?(Integer) && value.positive?

        instance_variable_set(:"@#{name}", value)
      end
    end

    def retrieval_max_candidates=(value)
      raise ArgumentError, "retrieval_max_candidates must be a positive Integer" unless value.is_a?(Integer) && value.positive?

      @retrieval_max_candidates = value
    end

    %i[
      snapshot_attribute_max_characters
      snapshot_related_record_max_characters
      snapshot_max_characters
      snapshot_max_chunks
    ].each do |name|
      define_method(:"#{name}=") do |value|
        unless value.is_a?(Integer) && value.positive?
          raise ArgumentError, "#{name} must be a positive Integer"
        end

        instance_variable_set(:"@#{name}", value)
      end
    end
  end
end
