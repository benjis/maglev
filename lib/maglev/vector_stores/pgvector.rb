# frozen_string_literal: true

require_relative "../chunk"
require_relative "base"
require_relative "document"

module Maglev
  module VectorStores
    class Pgvector < Base
      def initialize(chunk_model: Chunk)
        @chunk_model = chunk_model
      end

      def upsert(documents:)
        @chunk_model.transaction do
          documents.each do |document|
            scope = identity_scope(document)
            existing = scope.find_by(chunk_index: document.chunk_index, content_checksum: document.content_checksum)
            next if existing

            scope.where(chunk_index: document.chunk_index).delete_all
            @chunk_model.create!(
              owner_type: document.owner_type,
              owner_id: document.owner_id,
              owner_model_name: document.owner_model_name,
              owner: document.owner,
              source: document.source,
              chunk_index: document.chunk_index,
              content: document.content,
              content_checksum: document.content_checksum,
              embedding_model: document.embedding_model,
              embedding: document.embedding
            )
          end
        end
      end

      def search(vector:, filters:, limit:)
        scope = filters.reduce(@chunk_model.all) do |current_scope, (key, value)|
          current_scope.where(key => value)
        end
        scope.nearest_neighbors(:embedding, vector, distance: "cosine")
          .first(limit)
          .map { |row| document_for(row) }
      end

      def delete(ids:)
        ids.each do |id|
          owner_type, owner_id, source, chunk_index = id.split(":", 4)
          @chunk_model.where(owner_type: owner_type, owner_id: owner_id, source: source, chunk_index: chunk_index).delete_all
        end
      end

      def delete_by_owner(owner_type:, owner_id:)
        @chunk_model.where(owner_type: owner_type, owner_id: owner_id).delete_all
      end

      def healthcheck
        @chunk_model.connection.active? ? :ok : :unavailable
      end

      def capabilities
        {metadata_filtering: true, pgvector: true}
      end

      private

      def identity_scope(document)
        @chunk_model.where(
          owner_type: document.owner_type,
          owner_id: document.owner_id,
          owner_model_name: document.owner_model_name,
          source: document.source
        )
      end

      def document_for(row)
        Document.new(
          owner_type: row.owner_type,
          owner_id: row.owner_id,
          owner_model_name: row.owner_model_name,
          source: row.source,
          chunk_index: row.chunk_index,
          content: row.content,
          content_checksum: row.content_checksum,
          embedding_model: row.embedding_model,
          embedding: row.embedding,
          owner: row.owner,
          distance: row.respond_to?(:neighbor_distance) ? row.neighbor_distance : row.distance
        )
      end
    end
  end
end
