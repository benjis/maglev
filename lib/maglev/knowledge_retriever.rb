# frozen_string_literal: true

module Maglev
  class KnowledgeRetriever
    AUTHORIZED_OWNER_LIMIT = 1_000

    def retrieve(plan, question:)
      entry = Registry.fetch(plan.resource)
      raise ConfigurationError, "knowledge plan requires a registered knowledge resource" unless entry&.knowledge

      candidates = HybridCandidateSet.from_relation(
        relation: plan.base_relation,
        model_class: entry.model_class,
        trace_id: plan.trace_id,
        limit: AUTHORIZED_OWNER_LIMIT
      )
      retrieval = Retriever.new(entry.model_class).retrieve(
        question,
        **plan.retrieval,
        trace_id: plan.trace_id,
        candidates: candidates
      )
      KnowledgeEvidence.from_retrieval(retrieval)
    end
  end
end
