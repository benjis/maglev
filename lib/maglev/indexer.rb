# frozen_string_literal: true

require "digest"

require_relative "adapters/ruby_llm_embedding"
require_relative "chunk"
require_relative "chunker"
require_relative "errors"
require_relative "provider_call"
require_relative "vector_stores/document"

module Maglev
  class Indexer
    SOURCE = "snapshot"

    def initialize(record, chunk_model: Chunk, embedding_adapter: Maglev.configuration.embedding_adapter, embedding_dimensions: Maglev.configuration.embedding_dimensions, chunk_size: Maglev.configuration.chunk_size, vector_store: Maglev.configuration.vector_store)
      @record = record
      @chunk_model = chunk_model
      @embedding_adapter = embedding_adapter || Adapters::RubyLLMEmbedding.new
      @embedding_dimensions = embedding_dimensions
      @chunk_size = chunk_size
      @vector_store = vector_store
    end

    def index
      validate_owner_id!
      validate_storage_dimensions!
      ActiveSupport::Notifications.instrument("maglev.index.start", owner_type: @record.class.name, owner_id: @record.id)

      chunk_count = loop do
        snapshot = @record.maglev_snapshot
        chunks = Chunker.new(max_characters: @chunk_size).call(snapshot)
        prepared = @vector_store ? prepare_documents(chunks) : prepare_chunks(chunks)
        break chunks.length if persist_if_current(snapshot, prepared)
      end

      ActiveSupport::Notifications.instrument("maglev.index.success", owner_type: @record.class.name, owner_id: @record.id, chunk_count: chunk_count)
    rescue => error
      ActiveSupport::Notifications.instrument("maglev.index.failure", owner_type: @record.class.name, owner_id: @record.id, error_class: error.class.name)
      raise
    end

    def unindex
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
        existing = identity_scope.find_by(chunk_index: chunk_index, content_checksum: checksum)
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
      identity_scope.find_by(chunk_index: chunk[:chunk_index], content_checksum: chunk[:checksum])
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
        embedding_model: Maglev.configuration.embedding_model,
        embedding: chunk[:embedding]
      )
    end

    def prepare_documents(chunks)
      chunks.each_with_index.map { |content, chunk_index| document_for(content, chunk_index) }
    end

    def persist_documents(documents)
      @vector_store.delete_by_owner(owner_type: @record.class.name, owner_id: @record.id)
      @vector_store.upsert(documents: documents)
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
      embedding = ProviderCall.new.call(operation: "embed") { @embedding_adapter.embed(content) }
      validate_embedding!(embedding)
      embedding
    end

    def with_owner_lock(&block)
      return yield unless @record.respond_to?(:with_lock)

      @record.with_lock(&block)
    end

    def document_for(content, chunk_index)
      VectorStores::Document.new(
        owner_type: @record.class.name,
        owner_id: @record.id,
        owner_model_name: @record.class.name,
        owner: @record,
        source: SOURCE,
        chunk_index: chunk_index,
        content: content,
        content_checksum: Digest::SHA256.hexdigest(content),
        embedding_model: Maglev.configuration.embedding_model,
        embedding: embed(content)
      )
    end
  end
end
