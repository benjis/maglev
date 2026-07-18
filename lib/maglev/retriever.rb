# frozen_string_literal: true

require_relative "adapters/faraday_embedding"
require_relative "authorization"
require_relative "chunk"
require_relative "index_identity"
require_relative "provider_call"
require_relative "retrieval_outcome"
require_relative "retrieval_result"
require_relative "context_assembler"
require "securerandom"
require_relative "search_result"
require_relative "vector_stores/pgvector"

module Maglev
  class Retriever
    OWNER_DIVERSE_OVERFETCH = 4
    AUTHORIZED_OWNER_LIMIT = 1_000
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
      @candidate_ids = nil
      retrieval_outcome(
        query,
        limit: limit,
        owner: owner,
        user: user,
        minimum_similarity: minimum_similarity,
        chunks_per_owner: 1
      ).results
    end

    def retrieve(query, limit:, owner: nil, user: nil, minimum_similarity: nil, chunks_per_owner: 1, trace_id: SecureRandom.uuid, candidates: nil)
      started = monotonic
      validate_candidates!(candidates)
      @candidate_ids = candidates&.ids
      outcome = retrieval_outcome(query, limit: limit, owner: owner, user: user,
        minimum_similarity: minimum_similarity, chunks_per_owner: chunks_per_owner)
      context_started = monotonic
      context = ContextAssembler.new.assemble(outcome.results)
      context_ms = elapsed_ms(context_started)
      selected_ids = context.sources.map { |source| [source[:owner_type], source[:owner_id], source[:source], source[:chunk_index]] }
      selected = outcome.results.select do |result|
        selected_ids.include?([result.owner.class.name, result.owner.respond_to?(:id) ? result.owner.id : result.owner, result.source, result.chunk_index])
      end
      budget_rejected = outcome.results - selected
      rejected = outcome.rejected_results.map { |result| {source: result, reason: :relevance_threshold} } +
        budget_rejected.map { |result| {source: result, reason: :context_budget} }
      timings = @last_timings.merge(context_assembly_ms: context_ms, total_ms: elapsed_ms(started)).freeze
      reasons = rejected.map { |item| item[:reason] }
      if outcome.considered.empty?
        reasons << ((outcome.authorization_rejected_count.positive? || @authorization_filter_applied) ? :authorization_filtered : :no_documents)
      end
      reasons = reasons.uniq.freeze
      payload = {trace_id: trace_id, model: @model_class.name, considered_count: outcome.considered.size,
                 selected_count: selected.size, rejected_count: rejected.size, timings: timings}.freeze
      ActiveSupport::Notifications.instrument("maglev.retrieval.complete", payload)
      RetrievalResult.new(query: query, considered: outcome.considered, selected: selected, rejected: rejected,
        context: context.text, budgets: context.metadata, reasons: reasons, timings: timings, trace_id: trace_id)
    end

    def retrieval_outcome(query, limit:, owner: nil, user: nil, minimum_similarity: nil, chunks_per_owner: 1)
      @authorization_scope_empty = false
      @authorization_filter_applied = false
      @request_tenant_id = user ? Maglev.configuration.tenant_id(user: user) : nil
      threshold = resolve_threshold(minimum_similarity)
      validate_limit!(limit)
      validate_chunks_per_owner!(chunks_per_owner)
      @current_index_version = current_index_version
      embedding_started = monotonic
      embedding = ProviderCall.new.call(operation: "embed") { @embedding_adapter.embed(query) }
      embedding_ms = elapsed_ms(embedding_started)
      validate_embedding!(embedding)

      bounded_limit = candidate_limit(limit, owner: owner, chunks_per_owner: chunks_per_owner)
      retrieval_started = monotonic
      candidates = search_results(fetch_candidates(embedding, owner: owner, user: user, limit: bounded_limit))
      candidate_count = candidates.size
      candidates = authorize_results(candidates, user)
      authorization_rejected_count = candidate_count - candidates.size
      examined = sorted_results(candidates)
      accepted, rejected = apply_threshold(examined, threshold)
      projected = project_results(accepted, limit: limit, owner: owner, chunks_per_owner: chunks_per_owner)
      @last_timings = {embedding_ms: embedding_ms, retrieval_ms: elapsed_ms(retrieval_started)}.freeze

      RetrievalOutcome.new(
        results: projected,
        minimum_similarity: threshold,
        examined_count: examined.size,
        accepted_count: accepted.size,
        rejected_count: rejected.size,
        best_similarity: examined.filter_map(&:similarity).max,
        considered: examined,
        rejected_results: rejected,
        authorization_rejected_count: authorization_rejected_count
      )
    end

    private

    def validate_candidates!(candidates)
      return unless candidates
      unless candidates.is_a?(HybridCandidateSet) && candidates.model_class == @model_class
        raise ConfigurationError, "hybrid candidates do not match the retrieval model"
      end
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    def elapsed_ms(started) = ((monotonic - started) * 1000).round(3)

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

    def validate_limit!(value)
      return if value.is_a?(Integer) && value.positive?

      raise ArgumentError, "limit must be a positive Integer, got: #{value.inspect}"
    end

    def fetch_candidates(embedding, owner:, user:, limit:)
      if @vector_store
        filters = filters_for(owner, user: user)
        return [] if @authorization_scope_empty

        return @vector_store.search(vector: embedding, filters: filters, limit: limit)
      end

      scope = @chunk_model.where(owner_model_name: @model_class.name, index_version: @current_index_version)
      scope = scope.where(owner_id: @candidate_ids) if @candidate_ids
      scope = scope.where(owner: owner) if owner
      tenant_id = @request_tenant_id
      scope = scope.where(tenant_id: tenant_id) if tenant_id && @chunk_model.columns_hash.key?("tenant_id")
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
      [limit * chunks_per_owner * OWNER_DIVERSE_OVERFETCH,
        Maglev.configuration.retrieval_max_candidates].min
    end

    def sorted_results(results)
      results.sort_by { |result| result_sort_key(result) }
    end

    def result_sort_key(result)
      [result.distance || Float::INFINITY, source_priority(result.source_type), *owner_key(result.owner).map(&:to_s), result.chunk_index || Float::INFINITY]
    end

    def owner_key(owner)
      [owner.class.name, owner.respond_to?(:id) ? owner.id : owner]
    end

    def source_priority(type) = (type.to_sym == :attribute) ? 1 : 0

    def filters_for(owner, user:)
      filters = {owner_model_name: @model_class.name, index_version: @current_index_version}
      if owner
        filters[:owner_type] = owner.class.name
        filters[:owner_id] = owner.id
      end
      filters[:tenant_id] = @request_tenant_id
      authorized_ids = authorized_owner_ids(user) if !owner && @authorization.configured? && user
      owner_ids = if @candidate_ids && authorized_ids
        @candidate_ids & authorized_ids
      else
        @candidate_ids || authorized_ids
      end
      @authorization_scope_empty = true if owner_ids && owner_ids.empty?
      filters[:owner_ids] = owner_ids if owner_ids&.any?
      VectorStores::MetadataFilter.new(**filters.compact)
    end

    def authorized_owner_ids(user)
      scope = @authorization.scope(model: @model_class, user: user)
      @authorization_filter_applied = true
      return unless scope.respond_to?(:limit) && scope.respond_to?(:pluck)

      primary_key = @model_class.respond_to?(:primary_key) ? @model_class.primary_key : :id
      ids = scope.limit(AUTHORIZED_OWNER_LIMIT + 1).pluck(primary_key.to_sym)
      raise ConfigurationError, "authorization scope exceeds #{AUTHORIZED_OWNER_LIMIT} owner ids for vector retrieval" if ids.size > AUTHORIZED_OWNER_LIMIT

      @authorization_scope_empty = ids.empty?
      ids unless ids.empty?
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

    def authorize_results(results, user)
      return results unless @authorization.configured? && user

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
      rows.filter_map do |row|
        next unless compatible_owner_metadata?(row)
        owner = owner_for(row)
        next unless owner

        SearchResult.new(
          owner: owner,
          content: row.content,
          source: row.source,
          distance: row.respond_to?(:neighbor_distance) ? row.neighbor_distance : row.distance,
          chunk_index: row.respond_to?(:chunk_index) ? row.chunk_index : nil,
          source_identity: row.respond_to?(:source_identity) ? row.source_identity : row.source,
          source_type: (row.respond_to?(:source_type) && row.source_type) ? row.source_type : inferred_source_type(row.source),
          score: row.respond_to?(:score) ? row.score : nil
        )
      end
    end

    def owner_for(row)
      if row.owner
        row.owner
      elsif row.respond_to?(:owner_type) && row.respond_to?(:owner_id)
        @model_class.find_by(@model_class.primary_key => row.owner_id)
      end
    end

    def compatible_owner_metadata?(row)
      return true unless @vector_store
      return false if row.respond_to?(:owner_type) && row.owner_type != @model_class.name
      return false if row.respond_to?(:owner_model_name) && row.owner_model_name != @model_class.name
      if @request_tenant_id
        return false unless row.respond_to?(:tenant_id) && row.tenant_id == @request_tenant_id
      end
      if @vector_store.respond_to?(:contract_version) && @vector_store.contract_version >= 2
        return false unless row.respond_to?(:owner_type) && row.respond_to?(:owner_id) && row.respond_to?(:owner_model_name)
        if row.owner
          return false unless row.owner.is_a?(@model_class)
          return false unless row.owner.respond_to?(:id) && row.owner.id.to_s == row.owner_id.to_s
        end
      end

      true
    end

    def inferred_source_type(source)
      value = source.to_s
      return :attachment if value.include?("[blob:")
      return :rich_text if value.start_with?("rich_text.")
      return :related_record if value.start_with?("related:")
      return :related_record if value.include?("[") || value.include?(".")
      return :snapshot if value == "snapshot"

      :attribute
    end
  end
end
