# frozen_string_literal: true

require "securerandom"

module Maglev
  class HybridCoordinator
    SHAPES = %i[structured_first rag_first].freeze

    def initialize(retriever_factory:)
      @retriever_factory = retriever_factory
    end

    def call(request, decision)
      shape = request.options[:hybrid_plan]&.to_sym
      raise ConfigurationError, "a fixed hybrid plan (structured_first or rag_first) is required" unless SHAPES.include?(shape)

      entry = hybrid_entry(request)
      relation = authorized_relation(request, entry)
      trace_id = SecureRandom.uuid
      send(shape, request, decision, entry, relation, trace_id)
    end

    private

    def hybrid_entry(request)
      entries = request.resources.filter_map { |identifier| Registry.fetch(identifier) }
        .select { |entry| entry.queryable && entry.knowledge }
      raise ConfigurationError, "hybrid routing requires exactly one registered resource with structured and RAG capabilities" unless entries.one?

      entries.first
    end

    def authorized_relation(request, entry)
      relation = request.base_relation
      relation ||= entry.model_class.all if entry.queryable.allow_unscoped_model_queries
      unless relation && relation.klass == entry.model_class
        raise ConfigurationError, "hybrid requests require a matching authorized base relation"
      end
      relation
    end

    def structured_first(request, decision, entry, relation, trace_id)
      structured = structured_result(request, entry, relation)
      return wrap_non_success(structured, decision, :structured_first, trace_id) unless structured.status == :succeeded
      raise ConfigurationError, "hybrid structured stages require record plans" unless structured.kind == :relation

      ids = structured.value.pluck(entry.model_class.primary_key)
      candidates = candidate_set(entry, ids, request, trace_id)
      retrieval = retrieve(request, entry, candidates: candidates, trace_id: trace_id)
      evidence = [HybridEvidence.new(provenance: :structured, value: structured.evidence),
        HybridEvidence.new(provenance: :rag, value: retrieval)].freeze
      result(decision, trace_id, :structured_first, candidates.ids, evidence,
        ["structured filter", "RAG within typed candidates"])
    end

    def rag_first(request, decision, entry, relation, trace_id)
      retrieval = retrieve(request, entry, trace_id: trace_id)
      owners = retrieval.selected.map(&:owner)
      if owners.any? { |owner| !owner.is_a?(entry.model_class) }
        raise ConfigurationError, "hybrid retrieval returned mixed model candidates"
      end
      candidates = candidate_set(entry, owners.map(&:id), request, trace_id)
      candidate_relation = relation.where(entry.model_class.primary_key => candidates.ids)
      structured = structured_result(request, entry, candidate_relation)
      return wrap_non_success(structured, decision, :rag_first, trace_id) unless structured.status == :succeeded
      raise ConfigurationError, "hybrid structured stages require record plans" unless structured.kind == :relation

      records = structured.value.to_a
      missing = candidates.ids.size - records.size
      warnings = missing.positive? ? ["#{missing} stale, deleted, or unauthorized candidates were excluded."] : []
      evidence = [HybridEvidence.new(provenance: :rag, value: retrieval),
        HybridEvidence.new(provenance: :structured, value: structured.evidence)].freeze
      result(decision, trace_id, :rag_first, records, evidence,
        ["RAG candidate retrieval", "structured verification"], warnings: warnings)
    end

    def structured_result(request, entry, relation)
      plan = Maglev.plan(request.question, resource: entry.identifier, resources: request.resources,
        base_relation: relation, user: request.user, authorizer: request.options[:authorizer],
        constraints: request.options.fetch(:constraints, {}),
        adapter: request.options[:planner_adapter] || Maglev.configuration.planner_adapter)
      Maglev.execute(plan)
    end

    def retrieve(request, entry, trace_id:, candidates: nil)
      options = {limit: request.options.fetch(:limit, 10), user: request.user,
                 minimum_similarity: request.options[:minimum_similarity],
                 chunks_per_owner: request.options.fetch(:chunks_per_owner, 1), trace_id: trace_id}
      options[:candidates] = candidates if candidates
      @retriever_factory.call(entry.model_class).retrieve(request.question, **options)
    end

    def candidate_set(entry, ids, request, trace_id)
      HybridCandidateSet.new(model_class: entry.model_class, ids: ids,
        tenant_id: request.user && Maglev.configuration.tenant_id(user: request.user), trace_id: trace_id,
        limit: request.options.fetch(:candidate_limit, HybridCandidateSet::DEFAULT_LIMIT))
    end

    def result(decision, trace_id, shape, records, evidence, operations, warnings: [])
      Result.new(status: :succeeded, route: :hybrid, kind: :hybrid_answer,
        value: HybridAnswer.new(records: records), evidence: evidence, warnings: warnings,
        trace_id: trace_id, confidence: decision.confidence, reasons: decision.reasons,
        metadata: {plan_shape: shape, operations: operations.freeze}.freeze)
    end

    def wrap_non_success(structured, decision, shape, trace_id)
      Result.new(status: structured.status, route: :hybrid, kind: :none,
        warnings: structured.warnings, trace_id: trace_id, confidence: decision.confidence,
        reasons: decision.reasons, metadata: {plan_shape: shape}.freeze)
    end
  end
end
