# frozen_string_literal: true

require "digest"
require "json"

require_relative "chunker"
require_relative "errors"

module Maglev
  class IndexIdentity
    PAYLOAD_NAMESPACE = "maglev-index"
    FORMAT_VERSION = 3
    REPRESENTATION_VERSION = "maglev-knowledge-v0.3"

    attr_reader :representation_version, :resource_identifier, :knowledge_policy_digest

    def self.for(model_class:, configuration:, adapter:, chunk_size:)
      resource_identifier = model_class.maglev_resource_identifier if model_class.respond_to?(:maglev_resource_identifier)
      resource_identifier ||= model_class.name
      knowledge_config = model_class.maglev_config if model_class.respond_to?(:maglev_config)
      new(
        configuration: configuration,
        adapter: adapter,
        chunk_size: chunk_size,
        resource_identifier: resource_identifier,
        knowledge_config: knowledge_config
      )
    end

    def initialize(configuration:, adapter:, chunk_size:, resource_identifier:, knowledge_config:)
      @configuration = configuration
      @adapter = adapter
      @chunk_size = chunk_size
      @representation_version = REPRESENTATION_VERSION
      @resource_identifier = required_string(resource_identifier, "resource identifier")
      @knowledge_policy_digest = Digest::SHA256.hexdigest(JSON.generate(knowledge_policy(knowledge_config)))
    end

    def to_s
      digest = Digest::SHA256.hexdigest(JSON.generate([
        PAYLOAD_NAMESPACE,
        FORMAT_VERSION,
        representation_version,
        resource_identifier,
        knowledge_policy_digest,
        required_string(@configuration.embedding_model, "embedding model"),
        positive_integer(@configuration.embedding_dimensions, "embedding dimensions"),
        adapter_id,
        adapter_version,
        required_string(Chunker::ALGORITHM_VERSION, "chunking algorithm version"),
        positive_integer(@chunk_size, "chunk size"),
        required_string(@configuration.application_index_version, "application index version")
      ]))
      "v3-#{digest.first(61)}"
    end

    private

    def knowledge_policy(config)
      return [[], [], [], [], [], [], []] unless config

      [
        strings(config, :content_attributes),
        strings(config, :context_attributes),
        strings(config, :prohibited_attributes),
        strings(config, :tags),
        Array(config.relations).map { |relation| relation_policy(relation) },
        source_names(config, :attached_sources),
        source_names(config, :rich_text_sources)
      ]
    end

    def strings(config, name)
      Array(config.public_send(name)).map(&:to_s)
    end

    def source_names(config, name)
      Array(config.public_send(name)).map { |source| source.respond_to?(:name) ? source.name.to_s : source.to_s }
    end

    def relation_policy(relation)
      [
        relation.name.to_s,
        relation.depth,
        relation.limit,
        relation.inverse&.to_s,
        relation.order&.to_h&.map { |field, direction| [field.to_s, direction.to_s] }
      ]
    end

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
