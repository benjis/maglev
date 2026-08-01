# frozen_string_literal: true

module Maglev
  class BusinessOutcomeSynthesizer
    KEYS = %w[answer findings inferences recommendations assumptions limitations].freeze
    MAX_ITEMS = 20
    MAX_TEXT_BYTES = 2_000

    def initialize(adapter:)
      raise ConfigurationError, "outcome synthesis adapter must implement #synthesize" unless adapter&.respond_to?(:synthesize)

      @adapter = adapter
    end

    def synthesize(question:, execution:, semantic_context: nil)
      request = {
        question: question.to_s,
        evidence: execution.evidence,
        limitations: execution.limitations
      }
      request[:semantic_context] = semantic_context if semantic_context
      output = @adapter.synthesize(**request)
      validate_output!(output)
      evidence_by_id = execution.evidence.to_h { |item| [item.step_id, item] }
      findings = claims(output.fetch("findings"), evidence_by_id, :finding)
      inferences = claims(output.fetch("inferences"), evidence_by_id, :inference)
      recommendations = claims(output.fetch("recommendations"), evidence_by_id, :recommendation)
      limitations = (execution.limitations + strings(output.fetch("limitations"))).uniq.freeze

      {
        answer: output.fetch("answer"),
        findings: findings,
        inferences: inferences,
        recommendations: recommendations,
        assumptions: strings(output.fetch("assumptions")),
        limitations: limitations
      }.freeze
    end

    private

    def validate_output!(output)
      unless output.is_a?(Hash) && output.keys.sort == KEYS.sort &&
          valid_text?(output["answer"]) &&
          %w[findings inferences recommendations assumptions limitations].all? do |key|
            output[key].is_a?(Array) && output[key].length <= MAX_ITEMS
          end
        raise PermanentProviderError, "Outcome synthesis provider returned invalid output"
      end
    end

    def claims(values, evidence_by_id, kind)
      values.map do |value|
        expected_keys = (kind == :recommendation) ? %w[evidence text] : %w[evidence relationship text]
        unless value.is_a?(Hash) && value.keys.sort == expected_keys &&
            valid_text?(value["text"]) && value["evidence"].is_a?(Array) &&
            value["evidence"].length.between?(1, MAX_ITEMS) &&
            value["evidence"].uniq == value["evidence"]
          raise PermanentProviderError, "Outcome synthesis claim is invalid"
        end

        evidence = value.fetch("evidence").map do |identifier|
          evidence_by_id.fetch(identifier.to_s) do
            raise PermanentProviderError, "Outcome synthesis claim is not grounded in Evidence"
          end
        end
        relationship = relationship_for(value, kind)
        BusinessClaim.new(text: value.fetch("text"), evidence: evidence, relationship: relationship)
      end.freeze
    end

    def relationship_for(value, kind)
      return nil if kind == :recommendation

      relationship = value.fetch("relationship").to_s
      valid = (kind == :finding && relationship == "observed") ||
        (kind == :inference && relationship == "correlation")
      unless valid
        raise PermanentProviderError, "Outcome synthesis cannot present causality as fact"
      end

      relationship.to_sym
    end

    def strings(values)
      unless values.all? { |value| valid_text?(value) }
        raise PermanentProviderError, "Outcome synthesis provider returned invalid text"
      end

      values.map { |value| value.freeze }.freeze
    end

    def valid_text?(value)
      value.is_a?(String) && !value.empty? && value.bytesize <= MAX_TEXT_BYTES
    end
  end
end
