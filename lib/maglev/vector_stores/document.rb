# frozen_string_literal: true

module Maglev
  module VectorStores
    class Document
      attr_reader :id, :owner_type, :owner_id, :owner_model_name, :source, :source_identity, :source_type, :tenant_id,
        :chunk_index, :content, :content_checksum, :embedding_model,
        :index_version, :embedding, :owner, :distance, :score

      def initialize(owner_type:, owner_id:, owner_model_name:, source:, chunk_index:,
        content:, content_checksum:, embedding_model:, index_version:, embedding:, id: nil,
        owner: nil, distance: nil, score: nil, source_identity: nil, source_type: nil, tenant_id: nil)
        @owner_type = owner_type
        @owner_id = owner_id
        @owner_model_name = owner_model_name
        @source = source
        @source_identity = source_identity || source
        @source_type = (source_type || :snapshot).to_sym
        @tenant_id = tenant_id
        @chunk_index = chunk_index
        @content = content
        @content_checksum = content_checksum
        @embedding_model = embedding_model
        @index_version = index_version
        @embedding = embedding
        @id = id || "#{owner_type}:#{owner_id}:#{source}:#{chunk_index}"
        @owner = owner
        @distance = distance
        @score = (score.nil? && !distance.nil?) ? (1.0 - distance.to_f).clamp(0.0, 1.0) : score
        freeze
      end

      def metadata
        {
          owner_type: owner_type,
          owner_id: owner_id,
          owner_model_name: owner_model_name,
          source: source,
          source_identity: source_identity,
          source_type: source_type,
          tenant_id: tenant_id,
          chunk_index: chunk_index,
          index_version: index_version
        }
      end
    end
  end
end
