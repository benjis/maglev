# frozen_string_literal: true

require_relative "maglev/version"
require_relative "maglev/configuration"
require_relative "maglev/provider_configuration"
require_relative "maglev/errors"
require_relative "maglev/removed_interface"
require_relative "maglev/authorization"
require_relative "maglev/provider_call"
require_relative "maglev/knowledge_config"
require_relative "maglev/knowledge_registry"
require_relative "maglev/resource_config"
require_relative "maglev/schema_snapshot"
require_relative "maglev/registry"
require_relative "maglev/query_ir"
require_relative "maglev/query_validator"
require_relative "maglev/planner_adapter"
require_relative "maglev/planner"
require_relative "maglev/planner_evaluation"
require_relative "maglev/adapters/faraday_planner"
require_relative "maglev/result"
require_relative "maglev/hybrid_candidate_set"
require_relative "maglev/query_compiler"
require_relative "maglev/structured_executor"
require_relative "maglev/structured_result"
require_relative "maglev/trace"
require_relative "maglev/structured_evidence_builder"
require_relative "maglev/structured_answer_composer"
require_relative "maglev/knowledge_evidence"
require_relative "maglev/knowledge_retriever"
require_relative "maglev/knowledge_executor"
require_relative "maglev/resource_selector_adapter"
require_relative "maglev/resource_catalog"
require_relative "maglev/business_question_plan"
require_relative "maglev/business_question_plan_validator"
require_relative "maglev/business_question_plan_executor"
require_relative "maglev/business_question_planner"
require_relative "maglev/business_outcome"
require_relative "maglev/business_outcome_synthesizer"
require_relative "maglev/continuation_token"
require_relative "maglev/business_question_engine"
require_relative "maglev/snapshot"
require_relative "maglev/snapshot_budget"
require_relative "maglev/snapshot_builder"
require_relative "maglev/source_fragment"
require_relative "maglev/source_extractor"
require_relative "maglev/chunker"
require_relative "maglev/embedding_adapter"
require_relative "maglev/index_identity"
require_relative "maglev/index_generation"
require_relative "maglev/index_rebuilder"
require_relative "maglev/index_activator"
require_relative "maglev/adapters/faraday_client"
require_relative "maglev/adapters/faraday_embedding"
require_relative "maglev/generation_adapter"
require_relative "maglev/adapters/faraday_generation"
require_relative "maglev/extracted_document"
require_relative "maglev/attachment_extractor"
require_relative "maglev/search_result"
require_relative "maglev/retrieval_result"
require_relative "maglev/vector_stores/base"
require_relative "maglev/vector_stores/document"
require_relative "maglev/vector_stores/metadata_filter"
require_relative "maglev/vector_stores/document_id"
require_relative "maglev/vector_stores/memory"
require_relative "maglev/vector_stores/pgvector"
require_relative "maglev/response"
require_relative "maglev/prompt_builder"
require_relative "maglev/context_assembler"
require_relative "maglev/context_preview"
require_relative "maglev/indexer"
require_relative "maglev/index_diagnostics"
require_relative "maglev/index_state"
require_relative "maglev/reindex_job"
require_relative "maglev/retriever"
require_relative "maglev/schema_compiler"
require_relative "maglev/dependency_graph"
require_relative "maglev/content_source_graph"
require_relative "maglev/answerer"

require_relative "maglev/railtie" if defined?(Rails::Railtie)

module Maglev
  class << self
    def rebuild_index!(**options)
      IndexRebuilder.new(**options).rebuild!
    end

    def index_generation(generation)
      IndexGeneration.find_by(generation: generation.to_s)
    end

    def active_index_generation
      IndexGeneration.active
    end

    def activate_index_generation!(generation, **options)
      candidate = IndexGeneration.find_by!(generation: generation.to_s)
      IndexActivator.new(candidate, **options).activate!
    end

    def abort_index_generation!(generation)
      IndexGeneration.find_by!(generation: generation.to_s).abort!
    end
  end
end
