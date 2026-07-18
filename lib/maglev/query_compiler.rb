# frozen_string_literal: true

require_relative "errors"
require_relative "query_validator"

module Maglev
  class QueryCompilationError < Error
  end

  class StructuredPlan
    attr_reader :relation, :operations, :explanation, :warnings, :aggregate, :aggregate_column

    def initialize(relation:, operations:, explanation:, aggregate: nil, aggregate_column: nil, warnings: [])
      @relation = relation
      @operations = operations.freeze
      @explanation = explanation.to_s.freeze
      @warnings = warnings.freeze
      @aggregate = aggregate
      @aggregate_column = aggregate_column
      freeze
    end

    def records? = aggregate.nil?
    def aggregate? = !records?
    def executed? = false
    def to_sql = relation.to_sql
  end

  module ReadOnlyRelation
    MUTATION_METHODS = %i[
      build create create! create_or_find_by create_or_find_by! create_with create_with!
      delete delete_all delete_by destroy destroy_all destroy_by find_or_create_by
      find_or_create_by! first_or_create first_or_create! insert insert! insert_all
      insert_all! new touch_all update update! update_all update_counters upsert upsert_all
    ].freeze

    MUTATION_METHODS.each do |method_name|
      define_method(method_name) do |*|
        raise QueryCompilationError, "Structured query relations are read-only"
      end
    end
  end

  class QueryCompiler
    SAFE_SCOPE_KEYS = %i[where order limit distinct].freeze

    def initialize(snapshot:)
      @snapshot = snapshot
      @resources = snapshot.resources.to_h { |resource| [resource.identifier, resource] }
    end

    def compile(validation:, base_relation:)
      unless validation.is_a?(QueryValidator::Result) && validation.valid? && validation.ir && validation.snapshot.equal?(@snapshot)
        raise QueryCompilationError, "A valid query validation result is required"
      end
      unless defined?(ActiveRecord::Relation) && base_relation.is_a?(ActiveRecord::Relation)
        raise QueryCompilationError, "An ActiveRecord base relation is required"
      end

      ir = validation.ir
      resource = @resources[ir.root]
      root_model = @snapshot.model_class_for(ir.root)
      unless resource && root_model && base_relation.klass == root_model
        raise QueryCompilationError, "The base relation does not match the validated root resource"
      end

      relation = base_relation
      ir.scopes.each { |scope| relation = apply_scope(relation, resource, scope) }
      ir.joins.each { |path| relation = relation.joins(join_argument(path.segments)) }
      ir.filters.each { |predicate| relation = apply_predicate(relation, root_model, predicate) }
      ir.sort.each { |sort| relation = apply_sort(relation, root_model, sort) }
      relation = relation.distinct if ir.distinct
      relation = relation.limit([relation.limit_value, ir.limit].compact.min)
      relation = relation.readonly.extending(ReadOnlyRelation)

      StructuredPlan.new(
        relation: relation,
        aggregate: ir.aggregate,
        aggregate_column: aggregate_column(root_model, ir.aggregate),
        operations: operation_descriptions(ir),
        explanation: validation.explanation
      )
    rescue QueryCompilationError
      raise
    rescue NoMethodError, ArgumentError, ActiveRecord::ActiveRecordError => error
      raise QueryCompilationError, "Validated query could not be compiled: #{error.class.name}"
    end

    private

    def apply_scope(relation, resource, scope)
      declaration = resource.scopes.find { |candidate| candidate.fetch(:name) == scope.name }
      raise QueryCompilationError, "The validated scope is unavailable" unless declaration

      values = declaration.fetch(:parameters).keys.map { |name| literal_value(scope.parameters.fetch(name)) }
      scoped = ActiveRecord::Base.while_preventing_writes do
        relation.public_send(scope.name, *values)
      end
      if scoped.respond_to?(:unscope_values) && scoped.unscope_values.any?
        raise QueryCompilationError, "Registered scope cannot remove relation constraints"
      end
      unless scoped.is_a?(ActiveRecord::Relation) && scoped.klass == relation.klass
        raise QueryCompilationError, "Registered scope returned an incompatible relation"
      end
      raise QueryCompilationError, "Registered scope cannot widen the base relation" unless preserves_relation?(relation, scoped)

      scoped
    end

    def apply_predicate(relation, root_model, predicate)
      model = model_for_path(root_model, predicate.field.segments)
      column = model.arel_table[predicate.field.segments.last]
      value = literal_value(predicate.value)
      node = case predicate.operator
      when :eq then column.eq(value)
      when :not_eq then column.not_eq(value)
      when :gt then column.gt(value)
      when :gte then column.gteq(value)
      when :lt then column.lt(value)
      when :lte then column.lteq(value)
      when :in then column.in(value)
      when :not_in then column.not_in(value)
      when :is_null then column.eq(nil)
      when :is_not_null then column.not_eq(nil)
      when :between then column.between(value.first..value.last)
      else raise QueryCompilationError, "The validated predicate is unavailable"
      end
      relation.where(node)
    end

    def apply_sort(relation, root_model, sort)
      model = model_for_path(root_model, sort.field.segments)
      column = model.arel_table[sort.field.segments.last]
      relation.order((sort.direction == :desc) ? column.desc : column.asc)
    end

    def model_for_path(root_model, segments)
      segments[0...-1].reduce(root_model) { |model, name| model.reflect_on_association(name).klass }
    end

    def aggregate_column(root_model, aggregate)
      return unless aggregate&.field

      model_for_path(root_model, aggregate.field.segments).arel_table[aggregate.field.segments.last]
    end

    def preserves_relation?(base, scoped)
      base_values = base.values
      scoped_values = scoped.values
      return false unless (base_values.keys - scoped_values.keys).empty?
      return false unless (scoped_values.keys - base_values.keys - SAFE_SCOPE_KEYS).empty?
      return false unless base.where_clause.send(:predicates).all? { |predicate| scoped.where_clause.send(:predicates).include?(predicate) }
      return false unless Array(base.joins_values).all? { |join| scoped.joins_values.include?(join) }
      return false unless Array(base.left_outer_joins_values).all? { |join| scoped.left_outer_joins_values.include?(join) }
      return false unless Array(base.order_values).all? { |order| scoped.order_values.include?(order) }
      return false if base.limit_value && (!scoped.limit_value || scoped.limit_value > base.limit_value)
      return false if base.distinct_value && !scoped.distinct_value

      protected_keys = base_values.keys - SAFE_SCOPE_KEYS
      protected_keys.all? { |key| base_values[key] == scoped_values[key] }
    end

    def join_argument(segments)
      return segments.first.to_sym if segments.one?

      segments.reverse.reduce { |nested, segment| {segment.to_sym => nested} }
    end

    def literal_value(value)
      case value
      when QueryIR::Literal
        value.value
      when QueryIR::RelativeTime
        amount = value.amount.public_send(value.unit)
        (value.direction == "ago") ? Time.current - amount : Time.current + amount
      when Array
        value.map { |item| literal_value(item) }
      else
        value
      end
    end

    def operation_descriptions(ir)
      [
        *ir.scopes.map { |scope| "scope #{scope.name}" },
        *ir.joins.map { |join| "join #{join}" },
        *ir.filters.map { |filter| "filter #{filter.field} #{filter.operator}" },
        *ir.sort.map { |sort| "sort #{sort.field} #{sort.direction}" },
        ("distinct" if ir.distinct),
        "limit #{ir.limit}",
        ("aggregate #{ir.aggregate.function}" if ir.aggregate)
      ].compact.freeze
    end
  end
end
