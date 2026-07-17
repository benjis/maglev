# frozen_string_literal: true

require_relative "base"
require_relative "document"

module Maglev
  module VectorStores
    class Memory < Base
      Entry = Struct.new(:owner_type, :owner_id, :document)

      def initialize
        @documents = {}
        @mutex = Mutex.new
      end

      def fetch(ids:)
        requested_ids = ids.to_a
        documents = @mutex.synchronize { @documents }
        requested_ids.filter_map { |id| documents[id]&.document }
      end

      def upsert(documents:)
        staged = stage(documents)
        @mutex.synchronize do
          replacement = @documents.dup
          staged.each { |id, entry| replacement[id] = entry }
          @documents = replacement
        end
      end

      def replace_owner(owner_type:, owner_id:, documents:)
        staged = stage(documents)
        unless staged.all? { |_id, entry| entry.owner_type == owner_type && entry.owner_id == owner_id }
          raise ArgumentError, "replacement documents must match the requested owner"
        end

        @mutex.synchronize do
          conflict = staged.any? do |id, _entry|
            existing = @documents[id]
            existing && (existing.owner_type != owner_type || existing.owner_id != owner_id)
          end
          raise ArgumentError, "replacement document id belongs to another owner" if conflict

          replacement = @documents.reject do |_id, entry|
            entry.owner_type == owner_type && entry.owner_id == owner_id
          end
          staged.each { |id, entry| replacement[id] = entry }
          @documents = replacement
        end
      end

      def search(vector:, filters:, limit:)
        documents = @mutex.synchronize { @documents.values.map(&:document) }
        documents
          .select { |document| matches_filters?(document, filters) }
          .map { |document| with_distance(document, cosine_distance(vector, document.embedding)) }
          .sort_by(&:distance)
          .first(limit)
      end

      def delete(ids:)
        requested_ids = ids.to_a
        @mutex.synchronize do
          replacement = @documents.dup
          requested_ids.each { |id| replacement.delete(id) }
          @documents = replacement
        end
      end

      def delete_by_owner(owner_type:, owner_id:)
        @mutex.synchronize do
          @documents = @documents.reject do |_id, document|
            document.owner_type == owner_type && document.owner_id == owner_id
          end
        end
      end

      def healthcheck
        :ok
      end

      def capabilities
        {metadata_filtering: true, in_memory: true}
      end

      private

      def stage(documents)
        documents.map do |document|
          entry = Entry.new(document.owner_type, document.owner_id, document).freeze
          [document.id, entry]
        end
      end

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
          index_version: document.index_version,
          embedding: document.embedding,
          owner: document.owner,
          distance: distance
        )
      end
    end
  end
end
