# frozen_string_literal: true

module Maglev
  class Result
    STATUSES = %i[succeeded clarification_required unsupported failed].freeze
    KINDS = %i[relation scalar aggregate semantic_matches rag_answer hybrid_answer none].freeze

    attr_reader :status, :route, :kind, :value, :evidence, :warnings, :trace_id,
      :confidence, :reasons, :metadata

    def initialize(status:, route:, kind:, trace_id:, value: nil, evidence: nil, warnings: [],
      confidence: nil, reasons: [], metadata: {})
      raise ArgumentError, "invalid result status" unless STATUSES.include?(status)
      raise ArgumentError, "invalid result kind" unless KINDS.include?(kind)
      raise ArgumentError, "only successful results may carry a value" if status != :succeeded && !value.nil?

      @status = status
      @route = route.to_sym
      @kind = kind
      @value = value
      @evidence = evidence
      @warnings = Array(warnings).map { |warning| warning.to_s.freeze }.freeze
      @trace_id = trace_id.to_s.freeze
      @confidence = confidence
      @reasons = Array(reasons).map { |reason| reason.to_s.freeze }.freeze
      @metadata = metadata.freeze
      freeze
    end
  end
end
