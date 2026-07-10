# frozen_string_literal: true

module Maglev
  module VectorStores
    class Document
      attr_reader :id, :owner_type, :owner_id, :owner_model_name, :source,
        :chunk_index, :content, :content_checksum, :embedding_model,
        :embedding, :owner, :distance

      def initialize(owner_type:, owner_id:, owner_model_name:, source:, chunk_index:,
        content:, content_checksum:, embedding_model:, embedding:, id: nil,
        owner: nil, distance: nil)
        @owner_type = owner_type
        @owner_id = owner_id
        @owner_model_name = owner_model_name
        @source = source
        @chunk_index = chunk_index
        @content = content
        @content_checksum = content_checksum
        @embedding_model = embedding_model
        @embedding = embedding
        @id = id || "#{owner_type}:#{owner_id}:#{source}:#{chunk_index}"
        @owner = owner
        @distance = distance
        freeze
      end

      def metadata
        {
          owner_type: owner_type,
          owner_id: owner_id,
          owner_model_name: owner_model_name,
          source: source,
          chunk_index: chunk_index
        }
      end
    end
  end
end
