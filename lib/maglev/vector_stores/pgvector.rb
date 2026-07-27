# frozen_string_literal: true

require "digest"

require_relative "../chunk"
require_relative "base"
require_relative "document"
require_relative "metadata_filter"
require_relative "document_id"

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
            attributes = {
              owner_type: document.owner_type,
              owner_id: document.owner_id,
              owner_model_name: document.owner_model_name,
              owner: document.owner,
              source: document.source,
              chunk_index: document.chunk_index,
              content: document.content,
              content_checksum: document.content_checksum,
              embedding_model: document.embedding_model,
              index_version: document.index_version,
              embedding: document.embedding
            }
            if source_metadata_columns?
              attributes[:source_identity] = document.source_identity
              attributes[:source_type] = document.source_type
              attributes[:tenant_id] = document.tenant_id
            end
            if index_identity_columns?
              attributes[:resource_identifier] = document.resource_identifier
              attributes[:representation_version] = document.representation_version
              attributes[:knowledge_policy_digest] = document.knowledge_policy_digest
            end
            attributes[:generation] = document.generation if generation_column?
            attributes[:context] = document.context if context_column?
            @chunk_model.create!(attributes)
          end
        end
      end

      def fetch(ids:)
        ids.to_a.filter_map do |id|
          resource_identifier, owner_type, owner_id, source, chunk_index, index_version, generation = parse_id(id)
          conditions = {
            owner_type: owner_type,
            owner_id: owner_id,
            source: source,
            chunk_index: chunk_index,
            index_version: index_version
          }
          conditions[:resource_identifier] = resource_identifier if index_identity_columns?
          conditions[:generation] = generation if generation_column?
          row = @chunk_model.find_by(conditions)
          document_for(row) if row
        end
      end

      def replace_owner(owner_type:, owner_id:, documents:, generation: nil)
        staged = stage(documents)
        unless staged.all? do |attributes|
          attributes[:owner_type] == owner_type && attributes[:owner_id] == owner_id &&
              attributes[:generation] == generation
        end
          raise ArgumentError, "replacement documents must match the requested owner"
        end

        @chunk_model.transaction do
          lock_owner(owner_type, owner_id)
          scope = @chunk_model.where(owner_type: owner_type, owner_id: owner_id)
          scope = scope.where(generation: generation) if generation_column?
          scope.delete_all
          staged.each { |attributes| @chunk_model.create!(attributes) }
        end
      end

      def search(vector:, filters:, limit:)
        scope = MetadataFilter.coerce(filters).reduce(@chunk_model.all) do |current_scope, (key, value)|
          column = {owner_ids: :owner_id, source_types: :source_type}.fetch(key, key)
          current_scope.where(column => value)
        end
        scope.nearest_neighbors(:embedding, vector, distance: "cosine")
          .first(limit)
          .map { |row| document_for(row) }
      end

      def delete(ids:)
        ids.each do |id|
          resource_identifier, owner_type, owner_id, source, chunk_index, index_version, generation = parse_id(id)
          conditions = {
            owner_type: owner_type,
            owner_id: owner_id,
            source: source,
            chunk_index: chunk_index,
            index_version: index_version
          }
          conditions[:resource_identifier] = resource_identifier if index_identity_columns?
          conditions[:generation] = generation if generation_column?
          @chunk_model.where(conditions).delete_all
        end
      end

      def delete_by_owner(owner_type:, owner_id:)
        @chunk_model.transaction do
          lock_owner(owner_type, owner_id)
          @chunk_model.where(owner_type: owner_type, owner_id: owner_id).delete_all
        end
      end

      def healthcheck
        @chunk_model.connection.active? ? :ok : :unavailable
      end

      def capabilities
        {metadata_filtering: true, pgvector: true}
      end

      private

      def parse_id(id)
        DocumentId.parse(id)
      end

      def stage(documents)
        documents.map do |document|
          attributes = {
            owner_type: document.owner_type,
            owner_id: document.owner_id,
            owner_model_name: document.owner_model_name,
            owner: document.owner,
            source: document.source,
            chunk_index: document.chunk_index,
            content: document.content,
            content_checksum: document.content_checksum,
            embedding_model: document.embedding_model,
            index_version: document.index_version,
            embedding: document.embedding
          }
          if source_metadata_columns?
            attributes[:source_identity] = document.source_identity
            attributes[:source_type] = document.source_type
            attributes[:tenant_id] = document.tenant_id
          end
          if index_identity_columns?
            attributes[:resource_identifier] = document.resource_identifier
            attributes[:representation_version] = document.representation_version
            attributes[:knowledge_policy_digest] = document.knowledge_policy_digest
          end
          attributes[:generation] = document.generation if generation_column?
          attributes[:context] = document.context if context_column?
          attributes
        end
      end

      def source_metadata_columns?
        !@chunk_model.respond_to?(:columns_hash) || @chunk_model.columns_hash.key?("source_identity")
      end

      def context_column?
        !@chunk_model.respond_to?(:columns_hash) || @chunk_model.columns_hash.key?("context")
      end

      def index_identity_columns?
        !@chunk_model.respond_to?(:columns_hash) ||
          %w[resource_identifier representation_version knowledge_policy_digest].all? { |name| @chunk_model.columns_hash.key?(name) }
      end

      def generation_column?
        !@chunk_model.respond_to?(:columns_hash) || @chunk_model.columns_hash.key?("generation")
      end

      def lock_owner(owner_type, owner_id)
        key = Digest::SHA256.digest("#{owner_type}\0#{owner_id}").unpack1("q>")
        quoted_key = @chunk_model.connection.quote(key)
        @chunk_model.connection.execute("SELECT pg_advisory_xact_lock(#{quoted_key})")
      end

      def identity_scope(document)
        conditions = {
          owner_type: document.owner_type,
          owner_id: document.owner_id,
          owner_model_name: document.owner_model_name,
          source: document.source,
          index_version: document.index_version
        }
        conditions[:resource_identifier] = document.resource_identifier if index_identity_columns?
        conditions[:generation] = document.generation if generation_column?
        @chunk_model.where(conditions)
      end

      def document_for(row)
        Document.new(
          id: DocumentId.build(owner_type: row.owner_type, owner_id: row.owner_id,
            resource_identifier: (row.respond_to?(:resource_identifier) && row.resource_identifier) ? row.resource_identifier : row.owner_model_name,
            source_identity: ((row.respond_to?(:source_identity) && row.source_identity) ? row.source_identity : row.source),
            chunk_index: row.chunk_index, index_version: row.index_version,
            generation: (row.generation if generation_column?)),
          owner_type: row.owner_type,
          owner_id: row.owner_id,
          owner_model_name: row.owner_model_name,
          source: row.source,
          source_identity: row.respond_to?(:source_identity) ? row.source_identity : row.source,
          source_type: row.respond_to?(:source_type) ? row.source_type : :snapshot,
          tenant_id: row.respond_to?(:tenant_id) ? row.tenant_id : nil,
          resource_identifier: row.respond_to?(:resource_identifier) ? row.resource_identifier : row.owner_model_name,
          representation_version: row.respond_to?(:representation_version) ? row.representation_version : nil,
          knowledge_policy_digest: row.respond_to?(:knowledge_policy_digest) ? row.knowledge_policy_digest : nil,
          generation: (row.generation if generation_column?),
          chunk_index: row.chunk_index,
          content: row.content,
          context: row.respond_to?(:context) ? row.context : {},
          content_checksum: row.content_checksum,
          embedding_model: row.embedding_model,
          index_version: row.index_version,
          embedding: row.embedding,
          owner: row.owner,
          distance: distance_for(row)
        )
      end

      def distance_for(row)
        return row.neighbor_distance if row.respond_to?(:neighbor_distance)

        row.distance if row.respond_to?(:distance)
      end
    end
  end
end
