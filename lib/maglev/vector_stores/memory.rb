# frozen_string_literal: true

require_relative "base"
require_relative "document"

module Maglev
  module VectorStores
    class Memory < Base
      def initialize
        @documents = {}
      end

      def upsert(documents:)
        documents.each { |document| @documents[document.id] = document }
      end

      def search(vector:, filters:, limit:)
        @documents.values
          .select { |document| matches_filters?(document, filters) }
          .map { |document| with_distance(document, cosine_distance(vector, document.embedding)) }
          .sort_by(&:distance)
          .first(limit)
      end

      def delete(ids:)
        ids.each { |id| @documents.delete(id) }
      end

      def delete_by_owner(owner_type:, owner_id:)
        @documents.delete_if do |_id, document|
          document.owner_type == owner_type && document.owner_id == owner_id
        end
      end

      def healthcheck
        :ok
      end

      def capabilities
        {metadata_filtering: true, in_memory: true}
      end

      private

      def matches_filters?(document, filters)
        filters.all? { |key, value| document.metadata.fetch(key) == value }
      end

      def cosine_distance(left, right)
        dot = left.zip(right).sum { |a, b| a.to_f * b.to_f }
        left_norm = Math.sqrt(left.sum { |value| value.to_f**2 })
        right_norm = Math.sqrt(right.sum { |value| value.to_f**2 })
        return 1.0 if left_norm.zero? || right_norm.zero?

        1.0 - (dot / (left_norm * right_norm))
      end

      def with_distance(document, distance)
        Document.new(
          id: document.id,
          owner_type: document.owner_type,
          owner_id: document.owner_id,
          owner_model_name: document.owner_model_name,
          source: document.source,
          chunk_index: document.chunk_index,
          content: document.content,
          content_checksum: document.content_checksum,
          embedding_model: document.embedding_model,
          embedding: document.embedding,
          owner: document.owner,
          distance: distance
        )
      end
    end
  end
end
