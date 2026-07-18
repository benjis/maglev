# frozen_string_literal: true

require "securerandom"

module Maglev
  class RequestExecutor
    def initialize(router:, retriever_factory: ->(model) { Retriever.new(model) },
      answerer_factory: ->(model) { Answerer.new(model) })
      @router = router
      @retriever_factory = retriever_factory
      @answerer_factory = answerer_factory
    end

    def call(request)
      decision = @router.route(request)
      case decision.route
      when :unsupported, :clarification_required
        Result.new(status: decision.route, route: decision.route, kind: :none,
          trace_id: SecureRandom.uuid, confidence: decision.confidence, reasons: decision.reasons)
      when :hybrid
        HybridCoordinator.new(retriever_factory: @retriever_factory).call(request, decision)
      when :structured then execute_structured(request, decision)
      when :rag then execute_rag(request, decision)
      end
    end

    private

    def execute_structured(request, decision)
      entry = single_entry(request, capability: :queryable)
      relation = request.base_relation
      if relation.nil? && entry.queryable.allow_unscoped_model_queries
        relation = entry.model_class.all
      end
      raise ConfigurationError, "structured requests require an authorized base relation" unless relation

      plan = Maglev.plan(request.question, resource: entry.identifier, resources: request.resources,
        base_relation: relation, user: request.user, authorizer: request.options[:authorizer],
        constraints: request.options.fetch(:constraints, {}),
        adapter: request.options[:planner_adapter] || Maglev.configuration.planner_adapter)
      wrap_structured(Maglev.execute(plan), decision)
    end

    def execute_rag(request, decision)
      entry = single_entry(request, capability: :knowledge)
      limit = request.options.fetch(:limit, 10)
      if request.options[:answer]
        response = @answerer_factory.call(entry.model_class).ask(request.question, limit: limit,
          user: request.user, minimum_similarity: request.options[:minimum_similarity],
          chunks_per_owner: request.options[:chunks_per_owner])
        Result.new(status: :succeeded, route: :rag, kind: :rag_answer, value: response,
          evidence: response.sources, trace_id: response.metadata[:trace_id] || SecureRandom.uuid,
          confidence: decision.confidence, reasons: decision.reasons, metadata: response.metadata)
      else
        retrieval = @retriever_factory.call(entry.model_class).retrieve(request.question, limit: limit,
          user: request.user, minimum_similarity: request.options[:minimum_similarity],
          chunks_per_owner: request.options.fetch(:chunks_per_owner, 1))
        Result.new(status: :succeeded, route: :rag, kind: :semantic_matches, value: retrieval,
          evidence: retrieval.selected, trace_id: retrieval.trace_id, confidence: decision.confidence,
          reasons: decision.reasons, metadata: retrieval.metadata)
      end
    end

    def single_entry(request, capability:)
      entries = request.resources.filter_map { |identifier| Registry.fetch(identifier) }
        .select { |entry| entry.public_send(capability) }
      unless entries.one?
        raise ConfigurationError, "#{capability} routing requires exactly one registered resource"
      end
      entries.first
    end

    def wrap_structured(result, decision)
      Result.new(status: result.status, route: :structured, kind: result.kind, value: result.value,
        evidence: result.evidence, warnings: result.warnings, trace_id: result.trace_id,
        confidence: decision.confidence, reasons: decision.reasons, metadata: {plan: result.plan}.freeze)
    end
  end

  def self.request(question, mode: :auto, resources: nil, models: nil, base_relation: nil,
    user: nil, router: nil, retriever_factory: nil, answerer_factory: nil, **options)
    entries = Array(models).filter_map do |model|
      Registry.entries.find { |entry| entry.model_class == model }
    end
    identifiers = [*Array(resources), *entries.map(&:identifier)].compact.map(&:to_s).uniq
    if identifiers.empty? && base_relation
      entry = Registry.entries.find { |candidate| candidate.model_class == base_relation.klass }
      identifiers << entry.identifier if entry
    end
    if identifiers.empty?
      raise ConfigurationError, "an explicit resource, model, or base relation is required"
    end

    router ||= Router.new(classifier: Maglev.configuration.routing_adapter)
    executor_options = {router: router}
    executor_options[:retriever_factory] = retriever_factory if retriever_factory
    executor_options[:answerer_factory] = answerer_factory if answerer_factory
    RequestExecutor.new(**executor_options).call(Request.new(question: question, mode: mode,
      resources: identifiers, base_relation: base_relation, user: user, **options))
  end
end
