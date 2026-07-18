# frozen_string_literal: true

require_relative "query_compiler"
require_relative "structured_result"
require_relative "trace"
require_relative "structured_evidence_builder"
require "bigdecimal"

module Maglev
  class StructuredExecutionError < Error
  end

  class StructuredExecutor
    DEFAULT_TIMEOUT = 5

    def initialize(timeout: DEFAULT_TIMEOUT, role: nil, wrapper: nil)
      @timeout = timeout
      @role = role
      @wrapper = wrapper
      raise ArgumentError, "timeout must be positive" unless @timeout.respond_to?(:positive?) && @timeout.positive?
    end

    def execute(plan)
      raise StructuredExecutionError, "A structured plan is required" unless plan.is_a?(StructuredPlan)
      return protected_relation(plan.relation) if plan.records?

      execute_with_policy(plan.relation) { execute_aggregate(plan) }
    rescue StructuredExecutionError
      raise
    rescue ActiveRecord::ActiveRecordError => error
      raise StructuredExecutionError, "Structured query execution failed: #{error.class.name}"
    end

    private

    def protected_relation(relation)
      executor = self
      policy = Module.new do
        define_method(:exec_queries) do |*arguments|
          executor.send(:execute_with_policy, self) { super(*arguments) }
        end
        %i[calculate pluck pick exists? ids].each do |method_name|
          define_method(method_name) do |*arguments|
            executor.send(:execute_with_policy, self) { super(*arguments) }
          end
        end

        define_method(:load_async) { load }
      end
      relation.extending(policy)
    end

    def execute_with_policy(relation, &query)
      operation = proc { execute_read_only(relation, &query) }
      if @wrapper
        unwrapped_operation = operation
        operation = proc { @wrapper.call(&unwrapped_operation) }
      end
      return ActiveRecord::Base.connected_to(role: @role, prevent_writes: true, &operation) if @role

      ActiveRecord::Base.while_preventing_writes(&operation)
    rescue StructuredExecutionError
      raise
    rescue ActiveRecord::ActiveRecordError => error
      raise StructuredExecutionError, "Structured query execution failed: #{error.class.name}"
    end

    def execute_read_only(relation)
      connection = relation.connection
      connection.transaction(requires_new: true) do
        apply_database_policy(connection)
        yield
      end
    end

    def apply_database_policy(connection)
      unless connection.adapter_name.casecmp?("PostgreSQL")
        raise StructuredExecutionError, "Structured execution requires an adapter with enforced statement timeouts"
      end

      milliseconds = (@timeout.to_f * 1000).ceil
      connection.execute("SET LOCAL statement_timeout = #{milliseconds}")
      connection.execute("SET TRANSACTION READ ONLY")
    end

    def execute_aggregate(plan)
      aggregate = plan.aggregate
      values = if aggregate.function == :count
        plan.relation.pluck(plan.relation.klass.arel_table[plan.relation.klass.primary_key])
      else
        plan.relation.pluck(plan.aggregate_column)
      end

      case aggregate.function
      when :count then values.length
      when :sum then values.sum
      when :average then values.empty? ? nil : BigDecimal(values.sum.to_s) / values.length
      when :minimum then values.min
      when :maximum then values.max
      else raise StructuredExecutionError, "The aggregate is unavailable"
      end
    end
  end

  def self.structured_executor(configuration: Maglev.configuration)
    StructuredExecutor.new(
      timeout: configuration.structured_query_timeout,
      role: configuration.structured_query_role,
      wrapper: configuration.structured_query_executor_wrapper
    )
  end

  def self.execute(plan, executor: structured_executor,
    evidence_rows: Maglev.configuration.structured_evidence_max_rows,
    evidence_bytes: Maglev.configuration.structured_evidence_max_bytes)
    unless plan.is_a?(Planner::Plan)
      raise StructuredExecutionError, "A structured planner result is required"
    end

    unless plan.ready?
      status = (plan.status == :invalid) ? :failed : plan.status
      return StructuredResult.new(status: status, kind: :none, warnings: plan.warnings,
        plan: plan, trace_id: plan.trace_id)
    end
    unless plan.base_relation
      raise StructuredExecutionError, "The structured plan has no authorized base relation"
    end

    compiled = Trace.instrument(:compilation, trace_id: plan.trace_id, resource: plan.resource,
      operation: plan.ir.operation) do
      QueryCompiler.new(snapshot: plan.validation.snapshot).compile(
        validation: plan.validation, base_relation: plan.base_relation
      )
    end
    resource = plan.validation.snapshot.resources.find { |candidate| candidate.identifier == plan.resource }
    filters = plan.ir.filters.map(&:to_h)
    date_ranges = filters.select { |filter| filter["operator"] == "between" }

    if compiled.records?
      value = executor.execute(compiled)
      evidence = StructuredEvidenceBuilder.new(plan: plan, relation: value, resource: resource,
        rows: evidence_rows, bytes: evidence_bytes).build
      StructuredResult.new(status: :succeeded, kind: :relation, value: value, evidence: evidence,
        interpretation: plan.explanation, warnings: plan.warnings, plan: plan, trace_id: plan.trace_id)
    else
      value = Trace.instrument(:execution, trace_id: plan.trace_id, resource: plan.resource,
        operation: plan.ir.operation) { executor.execute(compiled) }
      scalar_size = JSON.generate("records" => [], "scalar" => value, "filters" => filters,
        "date_ranges" => date_ranges, "count" => 1, "truncated" => false).bytesize
      bounded_scalar = scalar_size <= evidence_bytes
      evidence = StructuredEvidence.new(scalar: bounded_scalar ? value : nil, filters: filters,
        date_ranges: date_ranges, count: bounded_scalar ? 1 : 0, truncated: !bounded_scalar)
      StructuredResult.new(status: :succeeded, kind: :aggregate, value: value, evidence: evidence,
        interpretation: plan.explanation, warnings: plan.warnings, plan: plan, trace_id: plan.trace_id)
    end
  end
end
