# frozen_string_literal: true

module Maglev
  class BusinessQuestionPlanner
    PLAN_SCHEMA = {
      type: "object",
      additionalProperties: false,
      required: %w[version steps],
      properties: {
        version: {const: BusinessQuestionPlan::VERSION},
        steps: {
          type: "array",
          minItems: 1,
          items: {
            type: "object",
            additionalProperties: false,
            required: %w[id kind resource depends_on dependency_types input],
            properties: {
              id: {type: "string"},
              kind: {enum: BusinessQuestionPlan::STEP_KINDS.map(&:to_s)},
              resource: {type: "string"},
              depends_on: {type: "array", items: {type: "string"}},
              dependency_types: {
                type: "object",
                additionalProperties: {enum: %w[records aggregate semantic_matches hybrid]}
              },
              input: {type: "object"}
            }
          }
        }
      }
    }.freeze

    def initialize(adapter:, snapshot:, authorized_resources:, limits:)
      @adapter = adapter
      @snapshot = snapshot
      @authorized_resources = authorized_resources
      @limits = limits
    end

    def plan(question:, planning_facts:, semantic_context: nil)
      unless @adapter&.respond_to?(:business_plan)
        raise ConfigurationError, "planner adapter must implement #business_plan"
      end

      request = {
        question: question.to_s,
        schema_snapshot: @snapshot,
        limits: @limits,
        plan_schema: PLAN_SCHEMA,
        planning_facts: planning_facts
      }
      request[:semantic_context] = semantic_context if semantic_context
      output = @adapter.business_plan(**request)
      raise PlanValidationError, "Planner returned an invalid Business Question Plan" unless output.is_a?(Hash)

      input = output["plan"] || output
      BusinessQuestionPlanValidator.new(
        snapshot: @snapshot,
        authorized_resources: @authorized_resources,
        limits: @limits
      ).call(input)
    end
  end
end
