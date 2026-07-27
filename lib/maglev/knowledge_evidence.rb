# frozen_string_literal: true

module Maglev
  class KnowledgeSource
    attr_reader :citation, :owner_type, :owner_id, :source, :chunk_index,
      :content, :context, :similarity

    def initialize(citation:, owner_type:, owner_id:, source:, chunk_index:, content:, context:, similarity:)
      @citation = citation.to_s.freeze
      @owner_type = owner_type.to_s.freeze
      @owner_id = owner_id
      @source = source.to_s.freeze
      @chunk_index = chunk_index
      @content = content.to_s.freeze
      @context = deep_freeze(context.to_h)
      @similarity = similarity
      freeze
    end

    private

    def deep_freeze(value)
      case value
      when Hash then value.to_h { |key, item| [deep_freeze(key), deep_freeze(item)] }.freeze
      when Array then value.map { |item| deep_freeze(item) }.freeze
      else value.frozen? ? value : value.freeze
      end
    end
  end

  class KnowledgeEvidence
    attr_reader :sources, :context, :reasons, :budgets, :trace_id

    def self.from_retrieval(retrieval)
      sources = retrieval.sources.map do |source|
        KnowledgeSource.new(
          citation: source.fetch(:marker).delete_prefix("[").delete_suffix("]"),
          owner_type: source.fetch(:owner_type),
          owner_id: source.fetch(:owner_id),
          source: source.fetch(:source),
          chunk_index: source.fetch(:chunk_index),
          content: source.fetch(:content),
          context: source.fetch(:context),
          similarity: source.fetch(:similarity)
        )
      end
      new(sources: sources, context: retrieval.context, reasons: retrieval.reasons, budgets: retrieval.budgets,
        trace_id: retrieval.trace_id)
    end

    def initialize(sources:, context:, reasons:, budgets:, trace_id:)
      @sources = sources.freeze
      @context = context.to_s.freeze
      @reasons = reasons.freeze
      @budgets = budgets.freeze
      @trace_id = trace_id.to_s.freeze
      freeze
    end
  end
end
