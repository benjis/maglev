# frozen_string_literal: true

module Maglev
  class PlannerAdapter
    def plan(question:, schema_snapshot:, constraints:, query_ir_schema:, planning_facts: {}, repair: nil,
      semantic_context: nil)
      raise NotImplementedError, "#{self.class.name} must implement #plan"
    end

    def business_plan(question:, schema_snapshot:, limits:, plan_schema:, planning_facts: {}, semantic_context: nil)
      request = {question: question, schema_snapshot: schema_snapshot, constraints: limits,
                 query_ir_schema: plan_schema, planning_facts: planning_facts}
      request[:semantic_context] = semantic_context if semantic_context
      plan(**request)
    end
  end

  class FakePlannerAdapter < PlannerAdapter
    attr_reader :requests

    def initialize(outputs)
      @outputs = Array(outputs).dup
      @requests = []
    end

    def plan(**request)
      @requests << request.freeze
      raise PermanentProviderError, "Fake planner has no remaining output" if @outputs.empty?

      @outputs.shift
    end
  end
end
