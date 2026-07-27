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
      return execute_grouped_aggregate(plan) if plan.group_by.any?

      values = if aggregate.function == :count
        plan.relation.pluck(plan.relation.klass.arel_table[plan.relation.klass.primary_key])
      else
        plan.relation.pluck(plan.aggregate_column)
      end

      aggregate_values(aggregate.function, values)
    end

    def execute_grouped_aggregate(plan)
      value_column = if plan.aggregate.function == :count
        plan.relation.klass.arel_table[plan.relation.klass.primary_key]
      else
        plan.aggregate_column
      end
      rows = plan.relation.except(:order).pluck(*plan.group_columns, value_column)
      grouped = rows.group_by { |row| Array(row).first(plan.group_columns.length) }
      if grouped.length > plan.group_limit
        raise StructuredExecutionError, "Grouped aggregate exceeds the authorized group limit"
      end

      grouped.map do |keys, members|
        values = members.map { |row| Array(row).last }
        value = aggregate_values(plan.aggregate.function, values)
        plan.group_by.each_with_index.to_h { |group, index| [group.label, keys.fetch(index)] }
          .merge(plan.aggregate.label => value)
      end.sort_by { |row| plan.group_by.map { |group| [row.fetch(group.label).nil? ? 0 : 1, row.fetch(group.label).to_s] } }
    end

    def aggregate_values(function, values)
      case function
      when :count then values.length
      when :sum then values.compact.sum
      when :average
        values = values.compact
        values.empty? ? nil : BigDecimal(values.sum.to_s) / values.length
      when :minimum then values.compact.min
      when :maximum then values.compact.max
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
      grouped = plan.ir.group_by.any?
      bounded_value = if grouped
        bound_grouped_rows(value, evidence_rows, evidence_bytes, filters, date_ranges)
      else
        scalar_size = JSON.generate("records" => [], "scalar" => value, "filters" => filters,
          "date_ranges" => date_ranges, "count" => 1, "truncated" => false).bytesize
        [value, [], scalar_size <= evidence_bytes, scalar_size > evidence_bytes]
      end
      scalar, records, included, truncated = bounded_value
      evidence = StructuredEvidence.new(records: records, scalar: included ? scalar : nil, filters: filters,
        date_ranges: date_ranges, count: if grouped
                                           records.length
                                         else
                                           (included ? 1 : 0)
                                         end, truncated: truncated)
      StructuredResult.new(status: :succeeded, kind: grouped ? :table : :aggregate, value: value, evidence: evidence,
        interpretation: plan.explanation, warnings: plan.warnings, plan: plan, trace_id: plan.trace_id)
    end
  end

  def self.bound_grouped_rows(rows, row_limit, byte_limit, filters, date_ranges)
    selected = []
    rows.each do |row|
      break if selected.length >= row_limit

      candidate = selected + [row]
      size = JSON.generate("records" => candidate, "scalar" => nil, "filters" => filters,
        "date_ranges" => date_ranges, "count" => candidate.length,
        "truncated" => candidate.length < rows.length).bytesize
      break if size > byte_limit

      selected = candidate
    end
    truncated = selected.length < rows.length
    [nil, selected.freeze, true, truncated]
  end
end
