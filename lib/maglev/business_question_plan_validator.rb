# frozen_string_literal: true

module Maglev
  class BusinessQuestionPlanValidator
    RETRIEVAL_KEYS = %w[chunks_per_owner limit minimum_similarity].freeze

    def initialize(snapshot:, authorized_resources:, limits:)
      @snapshot = snapshot
      @authorized_resources = authorized_resources.to_h do |identifier, capabilities|
        [identifier.to_s, capabilities.transform_keys(&:to_sym).freeze]
      end.freeze
      @limits = limits
    end

    def call(input)
      plan = BusinessQuestionPlan.build(input,
        authorized_resources: @authorized_resources.keys, limits: @limits)
      plan.steps.each { |step| validate_step!(step) }
      validate_dependency_types!(plan)
      validate_hybrid_dependencies!(plan)
      BusinessQuestionPlan.send(:validated_build, plan.to_h,
        authorized_resources: @authorized_resources.keys, limits: @limits)
    end

    private

    def validate_step!(step)
      capabilities = @authorized_resources.fetch(step.resource)
      case step.kind
      when :structured
        validate_structured!(step, capabilities)
      when :knowledge
        validate_knowledge!(step, capabilities)
      when :hybrid
        raise PlanValidationError, "Invalid hybrid step input" unless step.input.empty?
      end
    end

    def validate_structured!(step, capabilities)
      raise PlanValidationError, "Unauthorized structured step" unless capabilities[:structured]
      raise PlanValidationError, "Invalid structured step input" unless step.input.keys == ["ir"]

      result = QueryValidator.new(snapshot: @snapshot, root: step.resource,
        limits: {rows: @limits.fetch(:structured_result_size)}).call(step.input["ir"])
      raise PlanValidationError, "Invalid structured step" unless result.valid?
    end

    def validate_knowledge!(step, capabilities)
      raise PlanValidationError, "Unauthorized knowledge step" unless capabilities[:knowledge]
      raise PlanValidationError, "Invalid knowledge step input" unless step.input.keys == ["retrieval"]

      retrieval = step.input["retrieval"]
      unless retrieval.is_a?(Hash) && retrieval.keys.sort == RETRIEVAL_KEYS &&
          retrieval["limit"].is_a?(Integer) && retrieval["limit"].between?(1, @limits.fetch(:retrieval_size)) &&
          retrieval["chunks_per_owner"].is_a?(Integer) && retrieval["chunks_per_owner"].between?(1, 10) &&
          valid_similarity?(retrieval["minimum_similarity"])
        raise PlanValidationError, "Invalid knowledge step"
      end
    end

    def valid_similarity?(value)
      value.nil? || (value.is_a?(Numeric) && value.finite? && (0.0..1.0).cover?(value))
    end

    def validate_hybrid_dependencies!(plan)
      by_id = plan.steps.to_h { |step| [step.id, step] }
      plan.steps.select { |step| step.kind == :hybrid }.each do |step|
        kinds = step.depends_on.map { |id| by_id.fetch(id).kind }
        unless kinds.include?(:structured) && kinds.include?(:knowledge)
          raise PlanValidationError, "Hybrid steps require structured and knowledge dependencies"
        end
      end
    end

    def validate_dependency_types!(plan)
      by_id = plan.steps.to_h { |step| [step.id, step] }
      plan.steps.each do |step|
        step.dependency_types.each do |source_id, evidence_kind|
          source_kind = by_id.fetch(source_id).expected_evidence.fetch("kind")
          unless evidence_kind == source_kind
            raise PlanValidationError, "Business Question Plan contains an incompatible typed dependency"
          end
        end
      end
    end
  end
end
