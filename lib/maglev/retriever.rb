# frozen_string_literal: true

require_relative "adapters/ruby_llm_embedding"
require_relative "authorization"
require_relative "chunk"
require_relative "provider_call"
require_relative "search_result"
require_relative "vector_stores/pgvector"

module Maglev
  class Retriever
    def initialize(model_class, chunk_model: Chunk, embedding_adapter: Maglev.configuration.embedding_adapter, authorization: Authorization.new, vector_store: Maglev.configuration.vector_store)
      @model_class = model_class
      @chunk_model = chunk_model
      @embedding_adapter = embedding_adapter || Adapters::RubyLLMEmbedding.new
      @authorization = authorization
      @vector_store = vector_store
    end

    def search(query, limit:, owner: nil, user: nil)
      embedding = ProviderCall.new.call(operation: "embed") { @embedding_adapter.embed(query) }
      return search_vector_store(embedding, limit: limit, owner: owner, user: user) if @vector_store

      scope = @chunk_model.where(owner_model_name: @model_class.name)
      scope = scope.where(owner: owner) if owner
      scope = apply_authorization_scope(scope, user) unless owner
      rows = scope
        .nearest_neighbors(:embedding, embedding, distance: "cosine")

      unique_owner_results(rows).first(limit)
    end

    private

    def search_vector_store(embedding, limit:, owner:, user:)
      documents = @vector_store.search(vector: embedding, filters: filters_for(owner), limit: limit)
      unique_owner_results(documents).first(limit)
    end

    def filters_for(owner)
      filters = {owner_model_name: @model_class.name}
      if owner
        filters[:owner_type] = owner.class.name
        filters[:owner_id] = owner.id
      end
      filters
    end

    def apply_authorization_scope(scope, user)
      return scope unless @authorization.configured? && user

      authorized_scope = @authorization.scope(model: @model_class, user: user)
      if authorized_scope.respond_to?(:select)
        scope.where(owner_id: authorized_scope.select(:id))
      else
        scope
      end
    end

    def unique_owner_results(rows)
      seen_owners = {}
      results = []

      rows.each do |row|
        owner = owner_for(row)
        next if seen_owners[owner]

        seen_owners[owner] = true
        results << SearchResult.new(
          owner: owner,
          content: row.content,
          source: row.source,
          distance: row.respond_to?(:neighbor_distance) ? row.neighbor_distance : row.distance,
          chunk_index: row.respond_to?(:chunk_index) ? row.chunk_index : nil
        )
      end

      results
    end

    def owner_for(row)
      if row.owner
        row.owner
      elsif row.respond_to?(:owner_type) && row.respond_to?(:owner_id)
        row.owner_type.constantize.find(row.owner_id)
      end
    end
  end
end
