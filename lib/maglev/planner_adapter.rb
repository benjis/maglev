# frozen_string_literal: true

module Maglev
  class PlannerAdapter
    def plan(question:, schema_snapshot:, constraints:, query_ir_schema:, repair: nil)
      raise NotImplementedError, "#{self.class.name} must implement #plan"
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
