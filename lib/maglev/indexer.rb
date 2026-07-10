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
      chunks = Chunker.new(max_characters: @chunk_size).call(@record.maglev_snapshot)

      ActiveSupport::Notifications.instrument("maglev.index.start", owner_type: @record.class.name, owner_id: @record.id)
      @vector_store ? index_vector_store(chunks) : index_chunk_model(chunks)
      ActiveSupport::Notifications.instrument("maglev.index.success", owner_type: @record.class.name, owner_id: @record.id, chunk_count: chunks.length)
    rescue => error
      ActiveSupport::Notifications.instrument("maglev.index.failure", owner_type: @record.class.name, owner_id: @record.id, error_class: error.class.name)
      raise
    end

    def unindex
      identity_scope.delete_all
    end

    private

    def index_vector_store(chunks)
      documents = chunks.each_with_index.map { |content, chunk_index| document_for(content, chunk_index) }
      @vector_store.delete_by_owner(owner_type: @record.class.name, owner_id: @record.id)
      @vector_store.upsert(documents: documents)
    end

    def index_chunk_model(chunks)
      @chunk_model.transaction do
        chunks.each_with_index do |content, chunk_index|
          index_chunk(content, chunk_index)
        end
        delete_obsolete_chunks(chunks.length)
      end
    end

    def index_chunk(content, chunk_index)
      checksum = Digest::SHA256.hexdigest(content)
      existing = identity_scope.find_by(chunk_index: chunk_index, content_checksum: checksum)
      return if existing

      identity_scope.where(chunk_index: chunk_index).delete_all
      embedding = ProviderCall.new.call(operation: "embed") { @embedding_adapter.embed(content) }
      validate_embedding!(embedding)

      @chunk_model.create!(
        **identity,
        owner: @record,
        source: SOURCE,
        chunk_index: chunk_index,
        content: content,
        content_checksum: checksum,
        embedding_model: Maglev.configuration.embedding_model,
        embedding: embedding
      )
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

    def document_for(content, chunk_index)
      embedding = ProviderCall.new.call(operation: "embed") { @embedding_adapter.embed(content) }
      validate_embedding!(embedding)
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
        embedding: embedding
      )
    end
  end
end
