# frozen_string_literal: true

require_relative "adapters/faraday_embedding"
require_relative "authorization"
require_relative "chunk"
require_relative "index_identity"
require_relative "provider_call"
require_relative "retrieval_outcome"
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

    def search(query, limit:, owner: nil, user: nil, minimum_similarity: nil)
      retrieval_outcome(
        query,
        limit: limit,
        owner: owner,
        user: user,
        minimum_similarity: minimum_similarity,
        chunks_per_owner: 1
      ).results
    end

    def retrieval_outcome(query, limit:, owner: nil, user: nil, minimum_similarity: nil, chunks_per_owner: 1)
      threshold = resolve_threshold(minimum_similarity)
      validate_chunks_per_owner!(chunks_per_owner)
      @current_index_version = current_index_version
      embedding = ProviderCall.new.call(operation: "embed") { @embedding_adapter.embed(query) }
      validate_embedding!(embedding)

      bounded_limit = candidate_limit(limit, owner: owner, chunks_per_owner: chunks_per_owner)
      candidates = search_results(fetch_candidates(embedding, owner: owner, user: user, limit: bounded_limit))
      candidates = authorize_vector_store_results(candidates, user)
      examined = sorted_results(candidates)
      accepted, rejected = apply_threshold(examined, threshold)
      projected = project_results(accepted, limit: limit, owner: owner, chunks_per_owner: chunks_per_owner)

      RetrievalOutcome.new(
        results: projected,
        minimum_similarity: threshold,
        examined_count: examined.size,
        accepted_count: accepted.size,
        rejected_count: rejected.size,
        best_similarity: examined.filter_map(&:similarity).max
      )
    end

    private

    def resolve_threshold(request_threshold)
      threshold = request_threshold || Maglev.configuration.minimum_similarity
      validate_threshold!(threshold)
      threshold
    end

    def validate_threshold!(threshold)
      return if threshold.nil?

      unless threshold.is_a?(Numeric) && threshold.finite?
        raise ArgumentError, "minimum_similarity must be a finite Numeric in 0.0..1.0, got: #{threshold.inspect}"
      end
      return if (0.0..1.0).cover?(threshold)

      raise ArgumentError, "minimum_similarity must be in 0.0..1.0, got: #{threshold}"
    end

    def apply_threshold(results, threshold)
      return [results, []] if threshold.nil?

      accepted = []
      rejected = []
      results.each do |result|
        similarity = result.similarity
        if similarity && similarity >= threshold
          accepted << result
        else
          rejected << result
        end
      end
      [accepted, rejected]
    end

    def validate_chunks_per_owner!(value)
      return if value.is_a?(Integer) && value.positive?

      raise ArgumentError, "chunks_per_owner must be a positive Integer, got: #{value.inspect}"
    end

    def fetch_candidates(embedding, owner:, user:, limit:)
      if @vector_store
        return @vector_store.search(vector: embedding, filters: filters_for(owner), limit: limit)
      end

      scope = @chunk_model.where(owner_model_name: @model_class.name, index_version: @current_index_version)
      scope = scope.where(owner: owner) if owner
      scope = apply_authorization_scope(scope, user) unless owner
      scope.nearest_neighbors(:embedding, embedding, distance: "cosine").limit(limit)
    end

    def project_results(results, limit:, owner:, chunks_per_owner:)
      return results.first(limit) if owner

      groups = results.group_by { |result| owner_key(result.owner) }
      selected_owners = groups.values.sort_by { |chunks| result_sort_key(chunks.first) }.first(limit)
      selected_owners.flat_map { |chunks| chunks.first(chunks_per_owner) }.sort_by { |result| result_sort_key(result) }
    end

    def candidate_limit(limit, owner:, chunks_per_owner: 1)
      owner ? limit : limit * chunks_per_owner * OWNER_DIVERSE_OVERFETCH
    end

    def sorted_results(results)
      results.sort_by { |result| result_sort_key(result) }
    end

    def result_sort_key(result)
      [result.distance || Float::INFINITY, *owner_key(result.owner).map(&:to_s), result.chunk_index || Float::INFINITY]
    end

    def owner_key(owner)
      [owner.class.name, owner.respond_to?(:id) ? owner.id : owner]
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

    def authorize_vector_store_results(results, user)
      return results unless @vector_store && @authorization.configured? && user

      results.select { |result| @authorization.authorized?(record: result.owner, user: user) }
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
