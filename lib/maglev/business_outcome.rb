# frozen_string_literal: true

module Maglev
  class BusinessClaim
    RELATIONSHIPS = %i[observed correlation].freeze

    attr_reader :text, :evidence, :relationship

    def initialize(text:, evidence:, relationship: nil)
      if !relationship.nil? && !RELATIONSHIPS.include?(relationship)
        raise ArgumentError, "invalid business claim relationship"
      end

      @text = text.to_s.freeze
      @evidence = Array(evidence).freeze
      @relationship = relationship
      freeze
    end
  end

  class BusinessOutcome
    STATUSES = %i[answered clarification_required unsupported partial failed].freeze

    attr_reader :status, :answer, :evidence, :findings, :inferences, :recommendations,
      :assumptions, :limitations, :warnings, :trace_id, :clarification, :continuation

    def initialize(status:, trace_id:, answer: nil, evidence: nil, findings: [], inferences: [],
      recommendations: [], assumptions: [], limitations: [], warnings: [], clarification: nil,
      continuation: nil)
      raise ArgumentError, "invalid business outcome status" unless STATUSES.include?(status)
      raise ArgumentError, "only answered outcomes may carry an answer" if status != :answered && !answer.nil?

      @status = status
      @answer = answer&.to_s&.freeze
      @evidence = evidence
      @findings = Array(findings).freeze
      @inferences = Array(inferences).freeze
      @recommendations = Array(recommendations).freeze
      @assumptions = Array(assumptions).map { |assumption| assumption.to_s.freeze }.freeze
      @limitations = Array(limitations).map { |limitation| limitation.to_s.freeze }.freeze
      @warnings = Array(warnings).map { |warning| warning.to_s.freeze }.freeze
      @trace_id = trace_id.to_s.freeze
      @clarification = clarification&.freeze
      @continuation = continuation&.to_s&.freeze
      freeze
    end
  end
end
