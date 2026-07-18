# frozen_string_literal: true

require "digest"

require_relative "adapters/faraday_embedding"
require_relative "chunk"
require_relative "chunker"
require_relative "errors"
require_relative "index_identity"
require_relative "provider_call"
require_relative "vector_stores/document"

module Maglev
  class Indexer
    SOURCE = "snapshot"
    IdentityConfiguration = Struct.new(
      :embedding_model,
      :embedding_dimensions,
      :embedding_adapter_id,
      :embedding_adapter_version,
      :application_index_version
    )
    private_constant :IdentityConfiguration

    def initialize(record, chunk_model: Chunk, embedding_adapter: Maglev.configuration.embedding_adapter, embedding_dimensions: Maglev.configuration.embedding_dimensions, chunk_size: Maglev.configuration.chunk_size, vector_store: Maglev.configuration.vector_store, index_identity: nil, provider_call: ProviderCall.new)
      @record = record
      @chunk_model = chunk_model
      @embedding_adapter = embedding_adapter || Adapters::FaradayEmbedding.new
      @embedding_dimensions = embedding_dimensions
      @chunk_size = chunk_size
      @vector_store = vector_store
      @index_identity = index_identity
      @provider_call = provider_call
    end

    def index
      validate_owner_id!
      validate_storage_dimensions!
      prepare_index_identity
      ActiveSupport::Notifications.instrument("maglev.index.start", owner_type: @record.class.name, owner_id: @record.id)
      @embedding_count = 0

      index_metadata = nil
      chunk_count = loop do
        snapshot_result = if @record.respond_to?(:maglev_snapshot_result) && @record.class.respond_to?(:maglev_config) && @record.class.maglev_config
          @record.maglev_snapshot_result
        end
        snapshot = snapshot_result ? snapshot_result.to_s : @record.maglev_snapshot
        all_chunks = Chunker.new(max_characters: @chunk_size, max_chunks: nil).call(snapshot)
        chunks = all_chunks.first(Maglev.configuration.snapshot_max_chunks)
        budget_metadata = snapshot_result&.metadata || {truncated: false, sources: []}
        if all_chunks.length > chunks.length && budget_metadata.fetch(:sources, []).none? { |source| source[:kind] == :chunks }
          budget_metadata = budget_metadata.merge(
            truncated: true,
            sources: budget_metadata.fetch(:sources, []) + [{
              kind: :chunks,
              path: "snapshot.chunks",
              original_chunks: all_chunks.length,
              retained_chunks: chunks.length
            }]
          )
        end
        index_metadata = budget_metadata.merge(
          original_chunk_count: all_chunks.length,
          retained_chunk_count: chunks.length,
          chunk_limit: Maglev.configuration.snapshot_max_chunks
        )
        index_metadata = deep_freeze(index_metadata)
        prepared = @vector_store ? prepare_documents(chunks) : prepare_chunks(chunks)
        break chunks.length if persist_if_current(snapshot, prepared)
      end

      ActiveSupport::Notifications.instrument("maglev.index.success", owner_type: @record.class.name, owner_id: @record.id, chunk_count: chunk_count, budget: index_metadata)
    rescue => error
      ActiveSupport::Notifications.instrument("maglev.index.failure", owner_type: @record.class.name, owner_id: @record.id, error_class: error.class.name, budget: index_metadata)
      raise
    end

    def unindex
      return @vector_store.delete_by_owner(owner_type: @record.class.name, owner_id: @record.id) if @vector_store

      identity_scope.delete_all
    end

    private

    def persist_if_current(snapshot, prepared)
      with_owner_lock do
        next false unless @record.maglev_snapshot == snapshot

        @vector_store ? persist_documents(prepared) : persist_chunks(prepared)
      end
    end

    def prepare_chunks(chunks)
      chunks.each_with_index.map do |content, chunk_index|
        checksum = Digest::SHA256.hexdigest(content)
        existing = identity_scope.find_by(chunk_index: chunk_index, content_checksum: checksum, index_version: @index_version)
        embedding = embed(content) unless existing
        {content: content, chunk_index: chunk_index, checksum: checksum, embedding: embedding}
      end
    end

    def persist_chunks(chunks)
      return false unless chunks.all? { |chunk| chunk[:embedding] || matching_chunk?(chunk) }

      @chunk_model.transaction do
        chunks.each { |chunk| persist_chunk(chunk) }
        delete_obsolete_chunks(chunks.length)
      end
      true
    end

    def matching_chunk?(chunk)
      identity_scope.find_by(chunk_index: chunk[:chunk_index], content_checksum: chunk[:checksum], index_version: @index_version)
    end

    def persist_chunk(chunk)
      return if matching_chunk?(chunk)

      identity_scope.where(chunk_index: chunk[:chunk_index]).delete_all

      @chunk_model.create!(
        **identity,
        owner: @record,
        source: SOURCE,
        chunk_index: chunk[:chunk_index],
        content: chunk[:content],
        content_checksum: chunk[:checksum],
        embedding_model: @identity_configuration.embedding_model,
        index_version: @index_version,
        embedding: chunk[:embedding]
      )
    end

    def prepare_documents(chunks)
      prepared = chunks.each_with_index.map do |content, chunk_index|
        {
          id: stable_document_id(chunk_index),
          content: content,
          chunk_index: chunk_index,
          checksum: Digest::SHA256.hexdigest(content)
        }
      end
      existing_by_id = @vector_store.fetch(ids: prepared.map { |chunk| chunk[:id] }).to_h { |document| [document.id, document] }

      prepared.map do |chunk|
        existing = existing_by_id[chunk[:id]]
        reusable = existing && existing.content_checksum == chunk[:checksum] && existing.index_version == @index_version
        document_for(chunk, embedding: reusable ? existing.embedding : embed(chunk[:content]))
      end
    end

    def persist_documents(documents)
      @vector_store.replace_owner(owner_type: @record.class.name, owner_id: @record.id, documents: documents)
      true
    end

    def delete_obsolete_chunks(chunk_count)
      identity_scope.where.not(chunk_index: (0...chunk_count).to_a).delete_all
    end

    def identity_scope
      @chunk_model.where(identity.merge(source: SOURCE))
    end

    def identity
      {
        owner_type: @record.class.name,
        owner_id: @record.id,
        owner_model_name: @record.class.name
      }
    end

    def validate_owner_id!
      return if @record.id.is_a?(Integer)

      raise ConfigurationError, "Maglev v1 install migration uses bigint owner ids; UUID owner ids require a custom migration"
    end

    def validate_embedding!(embedding)
      return if embedding.respond_to?(:length) && embedding.length == @embedding_dimensions

      actual = embedding.respond_to?(:length) ? embedding.length : "unknown"
      raise ConfigurationError, "Embedding adapter returned #{actual} dimensions; expected #{@embedding_dimensions} dimensions"
    end

    def validate_storage_dimensions!
      return if @vector_store || !@chunk_model.respond_to?(:columns_hash)

      column = @chunk_model.columns_hash["embedding"]
      database_dimensions = column&.limit
      return unless database_dimensions && database_dimensions != @embedding_dimensions

      raise ConfigurationError,
        "Configured embedding dimensions #{@embedding_dimensions} do not match " \
        "#{@chunk_model.table_name}.embedding vector(#{database_dimensions})"
    end

    def embed(content)
      embedding = @provider_call.call(operation: "embed") { perform_embedding(content) }
      validate_embedding!(embedding)
      embedding
    end

    def perform_embedding(content)
      if @embedding_count >= Maglev.configuration.snapshot_max_chunks
        raise RetryableProviderError, "snapshot changed while indexing and exhausted the per-execution embedding budget"
      end

      @embedding_count += 1
      @embedding_adapter.embed(content)
    end

    def deep_freeze(value)
      case value
      when Hash
        value.to_h { |key, item| [key, deep_freeze(item)] }.freeze
      when Array
        value.map { |item| deep_freeze(item) }.freeze
      else
        value.freeze
      end
    end

    def prepare_index_identity
      configuration = Maglev.configuration
      @identity_configuration = IdentityConfiguration.new(
        embedding_model: configuration.embedding_model,
        embedding_dimensions: @embedding_dimensions,
        embedding_adapter_id: configuration.embedding_adapter_id,
        embedding_adapter_version: configuration.embedding_adapter_version,
        application_index_version: configuration.application_index_version
      )
      identity = @index_identity || IndexIdentity.new(
        configuration: @identity_configuration,
        adapter: @embedding_adapter,
        chunk_size: @chunk_size
      )
      @index_version = identity.to_s
    end

    def with_owner_lock(&block)
      return yield unless @record.respond_to?(:with_lock)

      @record.with_lock(&block)
    end

    def stable_document_id(chunk_index)
      "#{@record.class.name}:#{@record.id}:#{SOURCE}:#{chunk_index}"
    end

    def document_for(chunk, embedding:)
      VectorStores::Document.new(
        id: chunk[:id],
        owner_type: @record.class.name,
        owner_id: @record.id,
        owner_model_name: @record.class.name,
        owner: @record,
        source: SOURCE,
        chunk_index: chunk[:chunk_index],
        content: chunk[:content],
        content_checksum: chunk[:checksum],
        embedding_model: @identity_configuration.embedding_model,
        index_version: @index_version,
        embedding: embedding
      )
    end
  end
end
