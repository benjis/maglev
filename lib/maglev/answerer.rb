# frozen_string_literal: true

require_relative "configuration"
require_relative "adapters/faraday_generation"
require_relative "authorization"
require_relative "context_assembler"
require_relative "prompt_builder"
require_relative "provider_call"
require_relative "response"
require_relative "retriever"

module Maglev
  class Answerer
    def initialize(model_class, retriever: Retriever.new(model_class),
      generation_adapter: Maglev.configuration.generation_adapter,
      authorization: Authorization.new)
      @model_class = model_class
      @retriever = retriever
      @generation_adapter = generation_adapter || Adapters::FaradayGeneration.new
      @authorization = authorization
    end

    def ask(question, limit:, owner: nil, user: nil, minimum_similarity: nil, chunks_per_owner: nil)
      chunks_per_owner = validate_chunks_per_owner(chunks_per_owner)
      @authorization.authorize(record: owner, user: user) if owner

      outcome = @retriever.retrieval_outcome(
        question,
        limit: limit,
        owner: owner,
        user: user,
        minimum_similarity: minimum_similarity,
        chunks_per_owner: chunks_per_owner
      )

      results = outcome.results.select { |result| @authorization.authorized?(record: result.owner, user: user) }
      return Response.insufficient_context(question: question, retrieval_metadata: rejection_metadata(outcome)) if results.empty?

      context = nil
      ActiveSupport::Notifications.instrument("maglev.query.retrieval", model: @model_class.name, result_count: results.size) do
        context = ContextAssembler.new.assemble(results)
      end
      return Response.insufficient_context(question: question, retrieval_metadata: rejection_metadata(outcome)) if context.sources.empty?

      prompt = PromptBuilder.new.build(question: question, context: context.text)
      text = nil
      ActiveSupport::Notifications.instrument("maglev.query.generation", model: @model_class.name) do
        text = ProviderCall.new.call(operation: "generate") { @generation_adapter.generate(prompt) }
      end
      Response.new(
        text: text,
        sources: context.sources,
        metadata: context.metadata.merge(outcome.metadata).merge(question: question, owner_scope: owner && owner_scope(owner))
      )
    end

    private

    def validate_chunks_per_owner(value)
      return 1 if value.nil?

      unless value.is_a?(Integer) && value.positive?
        raise ArgumentError, "chunks_per_owner must be a positive Integer, got: #{value.inspect}"
      end
      value
    end

    def rejection_metadata(outcome)
      outcome.metadata
    end

    def owner_scope(owner)
      {owner_type: owner.class.name, owner_id: owner.respond_to?(:id) ? owner.id : nil}
    end
  end
end
