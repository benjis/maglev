# frozen_string_literal: true

require "securerandom"
require "digest"
require "json"

require_relative "index_generation"
require_relative "index_identity"
require_relative "indexer"
require_relative "registry"

module Maglev
  class IndexRebuilder
    class SourceChanged < StandardError; end
    IdentityConfiguration = Struct.new(
      :embedding_model,
      :embedding_dimensions,
      :embedding_adapter_id,
      :embedding_adapter_version,
      :application_index_version
    )
    private_constant :IdentityConfiguration

    class << self
      def manifest_for(resources:, embedding_adapter:, embedding_dimensions:, chunk_size:)
        configuration = Maglev.configuration
        identity_configuration = IdentityConfiguration.new(
          embedding_model: configuration.embedding_model,
          embedding_dimensions: embedding_dimensions,
          embedding_adapter_id: configuration.embedding_adapter_id,
          embedding_adapter_version: configuration.embedding_adapter_version,
          application_index_version: configuration.application_index_version
        )
        resources.to_h do |model_class|
          identity = IndexIdentity.for(
            model_class: model_class,
            configuration: identity_configuration,
            adapter: embedding_adapter,
            chunk_size: chunk_size
          )
          inventory = inventory_for(model_class)
          [
            identity.resource_identifier,
            {
              "index_version" => identity.to_s,
              "representation_version" => identity.representation_version,
              "knowledge_policy_digest" => identity.knowledge_policy_digest,
              "record_count" => inventory.fetch(:record_count),
              "inventory_digest" => inventory.fetch(:digest)
            }
          ]
        end
      end

      def inventory_for(model_class)
        digest = Digest::SHA256.new
        count = 0
        model_class.find_each do |record|
          count += 1
          digest.update(JSON.generate([record.id.to_s, snapshot_fingerprint(record)]))
        end
        {record_count: count, digest: digest.hexdigest}.freeze
      end

      private

      def snapshot_fingerprint(record)
        result = if record.respond_to?(:maglev_snapshot_result) &&
            record.class.respond_to?(:maglev_config) && record.class.maglev_config
          record.maglev_snapshot_result
        end
        text = result ? result.to_s : record.maglev_snapshot
        context = result&.metadata&.fetch(:knowledge_context, {}) || {}
        Digest::SHA256.hexdigest(JSON.generate([text, context]))
      end
    end

    def initialize(resources: nil, vector_store: Maglev.configuration.vector_store,
      embedding_adapter: Maglev.configuration.embedding_adapter,
      embedding_dimensions: Maglev.configuration.embedding_dimensions,
      chunk_size: Maglev.configuration.chunk_size,
      generation: SecureRandom.uuid, heartbeat_interval: 5)
      @resources = normalize_resources(resources)
      @vector_store = vector_store
      @embedding_adapter = embedding_adapter
      @embedding_dimensions = embedding_dimensions
      @chunk_size = chunk_size
      @generation_name = generation
      @heartbeat_interval = heartbeat_interval
    end

    def rebuild!
      manifest = self.class.manifest_for(
        resources: @resources,
        embedding_adapter: @embedding_adapter,
        embedding_dimensions: @embedding_dimensions,
        chunk_size: @chunk_size
      )
      generation = IndexGeneration.start!(
        generation: @generation_name,
        representation_version: IndexIdentity::REPRESENTATION_VERSION,
        manifest: manifest,
        expected_record_count: manifest.values.sum { |entry| entry.fetch("record_count") }
      )
      heartbeat = start_heartbeat(generation)

      @resources.each do |model_class|
        model_class.find_each do |record|
          Indexer.new(
            record,
            vector_store: @vector_store,
            embedding_adapter: @embedding_adapter,
            embedding_dimensions: @embedding_dimensions,
            chunk_size: @chunk_size,
            generation: generation.generation
          ).index
          generation.record_indexed!
        end
      end
      current_manifest = self.class.manifest_for(
        resources: @resources,
        embedding_adapter: @embedding_adapter,
        embedding_dimensions: @embedding_dimensions,
        chunk_size: @chunk_size
      )
      unless current_manifest == manifest
        raise SourceChanged, "knowledge resources changed while the index generation was building"
      end
      generation.complete!
    rescue => error
      generation&.fail!(error)
      raise
    ensure
      stop_heartbeat(heartbeat)
    end

    private

    def normalize_resources(resources)
      values = resources || Registry.entries.select(&:knowledge).map(&:model_class)
      values.map { |resource| resource.respond_to?(:model_class) ? resource.model_class : resource }.uniq.freeze
    end

    def start_heartbeat(generation)
      Thread.new do
        loop do
          sleep @heartbeat_interval
          generation.heartbeat!
        end
      rescue ActiveRecord::RecordNotFound
        nil
      end
    end

    def stop_heartbeat(thread)
      return unless thread

      thread.kill
      thread.join
    end
  end
end
