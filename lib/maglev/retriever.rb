# frozen_string_literal: true

require_relative "adapters/faraday_embedding"
require_relative "authorization"
require_relative "chunk"
require_relative "index_identity"
require_relative "provider_call"
require_relative "search_result"
require_relative "vector_stores/pgvector"

module Maglev
  class Retriever
    OWNER_DIVERSE_OVERFETCH = 2
    IdentityConfiguration = Struct.new(
      :embedding_model,
      :embedding_dimensions,
      :embedding_adapter_id,
      :embedding_adapter_version,
      :application_index_version
    )
    private_constant :IdentityConfiguration

    def initialize(model_class, chunk_model: Chunk, embedding_adapter: Maglev.configuration.embedding_adapter, embedding_dimensions: Maglev.configuration.embedding_dimensions, chunk_size: Maglev.configuration.chunk_size, authorization: Authorization.new, vector_store: Maglev.configuration.vector_store)
      @model_class = model_class
      @chunk_model = chunk_model
      @embedding_adapter = embedding_adapter || Adapters::FaradayEmbedding.new
      @embedding_dimensions = embedding_dimensions
      @chunk_size = chunk_size
      @authorization = authorization
      @vector_store = vector_store
    end

    def search(query, limit:, owner: nil, user: nil)
      @current_index_version = current_index_version
      embedding = ProviderCall.new.call(operation: "embed") { @embedding_adapter.embed(query) }
      validate_embedding!(embedding)
      return search_vector_store(embedding, limit: limit, owner: owner, user: user) if @vector_store

      scope = @chunk_model.where(owner_model_name: @model_class.name, index_version: @current_index_version)
      scope = scope.where(owner: owner) if owner
      scope = apply_authorization_scope(scope, user) unless owner
      rows = scope
        .nearest_neighbors(:embedding, embedding, distance: "cosine")
        .limit(candidate_limit(limit, owner: owner))

      results_for(rows, limit: limit, owner: owner)
    end

    private

    def search_vector_store(embedding, limit:, owner:, user:)
      documents = @vector_store.search(
        vector: embedding,
        filters: filters_for(owner),
        limit: candidate_limit(limit, owner: owner)
      )
      results_for(documents, limit: limit, owner: owner)
    end

    def candidate_limit(limit, owner:)
      owner ? limit : limit * OWNER_DIVERSE_OVERFETCH
    end

    def results_for(rows, limit:, owner:)
      results = owner ? search_results(rows) : unique_owner_results(rows)
      results.first(limit)
    end

    def filters_for(owner)
      filters = {owner_model_name: @model_class.name, index_version: @current_index_version}
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

    def current_index_version
      configuration = Maglev.configuration
      identity_configuration = IdentityConfiguration.new(
        embedding_model: configuration.embedding_model,
        embedding_dimensions: @embedding_dimensions,
        embedding_adapter_id: configuration.embedding_adapter_id,
        embedding_adapter_version: configuration.embedding_adapter_version,
        application_index_version: configuration.application_index_version
      )
      IndexIdentity.new(
        configuration: identity_configuration,
        adapter: @embedding_adapter,
        chunk_size: @chunk_size
      ).to_s
    end

    def validate_embedding!(embedding)
      return if embedding.respond_to?(:length) && embedding.length == @embedding_dimensions

      actual = embedding.respond_to?(:length) ? embedding.length : "unknown"
      raise ConfigurationError, "Embedding adapter returned #{actual} dimensions; expected #{@embedding_dimensions} dimensions"
    end

    def unique_owner_results(rows)
      seen_owners = {}

      search_results(rows).select do |result|
        next false if seen_owners[result.owner]

        seen_owners[result.owner] = true
      end
    end

    def search_results(rows)
      rows.map do |row|
        SearchResult.new(
          owner: owner_for(row),
          content: row.content,
          source: row.source,
          distance: row.respond_to?(:neighbor_distance) ? row.neighbor_distance : row.distance,
          chunk_index: row.respond_to?(:chunk_index) ? row.chunk_index : nil
        )
      end
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
