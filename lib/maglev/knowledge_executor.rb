# frozen_string_literal: true

module Maglev
  class KnowledgeExecutor
    def initialize(retriever: KnowledgeRetriever.new,
      generation_adapter: Maglev.configuration.generation_adapter)
      @retriever = retriever
      @generation_adapter = generation_adapter
    end

    def execute(plan, question:)
      evidence = @retriever.retrieve(plan, question: question)
      if evidence.sources.empty?
        return Result.new(status: :unsupported, route: :knowledge, kind: :none,
          evidence: evidence, warnings: ["No authorized knowledge evidence was found."],
          trace_id: plan.trace_id)
      end

      answer = begin
        generate(question, evidence.context, evidence)
      rescue => error
        return Result.new(status: :failed, route: :knowledge, kind: :none,
          evidence: evidence, trace_id: plan.trace_id,
          metadata: {generation_error: error.class.name}.freeze)
      end
      Result.new(status: :succeeded, route: :knowledge, kind: :rag_answer,
        value: answer, evidence: evidence, trace_id: plan.trace_id)
    end

    private

    def generate(question, context, evidence)
      unless @generation_adapter&.respond_to?(:generate)
        raise ConfigurationError, "generation adapter is not configured"
      end

      prompt = PromptBuilder.new.build(question: question, context: context)
      answer = ProviderCall.new.call(operation: "generate") { @generation_adapter.generate(prompt) }
      unless answer.is_a?(String) && evidence.sources.any? { |source| answer.include?("[#{source.citation}]") }
        raise GroundingError, "Knowledge answers must cite retrieved evidence"
      end

      answer.freeze
    end
  end
end
