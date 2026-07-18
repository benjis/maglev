# frozen_string_literal: true

require "date"
require "time"
require_relative "query_ir"
require_relative "schema_snapshot"

module Maglev
  class QueryValidator
    attr_reader :policy_limits
    ROOT_KEYS = %w[version root operation scopes filters joins sort distinct limit aggregate].freeze
    OPERATIONS = %w[records aggregate].freeze
    OPERATORS = %w[eq not_eq gt gte lt lte in not_in is_null is_not_null between].freeze
    COMPARISON_OPERATORS = %w[gt gte lt lte between].freeze
    ARRAY_OPERATORS = %w[in not_in between].freeze
    NULL_OPERATORS = %w[is_null is_not_null].freeze
    NUMERIC_TYPES = %i[integer float decimal].freeze
    TIME_TYPES = %i[date datetime timestamp time].freeze
    DEFAULT_LIMITS = {rows: 100, operations: 30, joins: 2, complexity: 100}.freeze

    Error = Struct.new(:code, :message, :path, :details) do
      def initialize(**attributes)
        attributes[:path] = Array(attributes[:path]).freeze
        attributes[:details] = (attributes[:details] || {}).freeze
        super
        freeze
      end
    end
    Result = Struct.new(:ir, :errors, :explanation, :snapshot) do
      def initialize(**attributes)
        attributes[:errors] = Array(attributes[:errors]).freeze
        super
        freeze
      end

      def valid? = errors.empty?
    end

    def initialize(snapshot:, root:, limits: {})
      @snapshot = snapshot
      @root = root.to_s
      @resources = snapshot.resources.to_h { |resource| [resource.identifier, resource] }
      resource_limits = @resources[@root]&.limits || {}
      requested = limits.transform_keys(&:to_sym)
      @limits = DEFAULT_LIMITS.merge(resource_limits).merge(requested) do |_key, left, right|
        [left, right].min
      end
      @policy_limits = @limits.freeze
    end

    def call(input)
      @errors = []
      unless input.is_a?(Hash) && input.keys.all? { |key| key.is_a?(String) }
        error(:invalid_ir, "Query IR must be an object with string keys", [])
        return result
      end
      unknown = input.keys - ROOT_KEYS
      error(:invalid_ir, "Query IR contains unknown keys", [], keys: unknown.sort) if unknown.any?
      error(:invalid_ir, "Unsupported Query IR version", ["version"]) unless input["version"] == 1
      error(:unregistered, "The requested root resource is unavailable", ["root"], resource: @root) unless input["root"] == @root && @resources.key?(@root)
      error(:invalid_ir, "Unknown operation", ["operation"]) unless OPERATIONS.include?(input["operation"])
      return result if @errors.any?

      scopes = validate_scopes(input.fetch("scopes", []))
      joins = validate_joins(input.fetch("joins", []))
      filters = validate_filters(input.fetch("filters", []), joins)
      sort = validate_sort(input.fetch("sort", []), joins)
      distinct = input.fetch("distinct", false)
      error(:invalid_ir, "Distinct must be boolean", ["distinct"]) unless [true, false].include?(distinct)
      limit = validate_limit(input.fetch("limit", @limits[:rows]))
      aggregate = validate_aggregate(input["operation"], input["aggregate"], joins)
      operation_count = scopes.length + filters.length + joins.length + sort.length + (distinct ? 1 : 0) + (aggregate ? 1 : 0)
      error(:limit_exceeded, "Operation limit exceeded", [], limit: @limits[:operations]) if operation_count > @limits[:operations]
      complexity = filters.sum { |filter| 1 + filter.field.segments.length } + scopes.length * 2 + joins.sum { |join| join.segments.length * 3 } + sort.length + (aggregate ? 2 : 0)
      error(:limit_exceeded, "Query complexity exceeded", [], limit: @limits[:complexity]) if complexity > @limits[:complexity]
      return result if @errors.any?

      ir = QueryIR::Query.new(version: 1, root: @root, operation: input["operation"], scopes: scopes,
        filters: filters, joins: joins, sort: sort, distinct: distinct, limit: limit, aggregate: aggregate)
      Result.new(ir: ir, errors: [], explanation: explain(ir), snapshot: @snapshot)
    rescue KeyError, TypeError, ArgumentError
      error(:invalid_ir, "Malformed Query IR", [])
      result
    end

    private

    def validate_scopes(values)
      return invalid_collection("Scopes", ["scopes"]) unless values.is_a?(Array)
      schemas = @resources.fetch(@root).scopes.to_h { |scope| [scope.fetch(:name), scope] }
      values.each_with_index.filter_map do |value, index|
        unless exact_hash?(value, %w[name parameters]) && value["name"].is_a?(String) && value.fetch("parameters", {}).is_a?(Hash)
          error(:invalid_ir, "Invalid scope", ["scopes", index])
          next
        end
        schema = schemas[value["name"]]
        unless schema
          error(:unregistered, "The requested scope is not registered", ["scopes", index, "name"], resource: @root)
          next
        end
        parameters = validate_parameters(value.fetch("parameters", {}), schema.fetch(:parameters), ["scopes", index, "parameters"])
        QueryIR::Scope.new(name: value["name"], parameters: parameters)
      end
    end

    def validate_parameters(values, schemas, path)
      unknown = values.keys - schemas.keys
      error(:invalid_ir, "Unknown scope parameters", path, keys: unknown.sort) if unknown.any?
      schemas.each_with_object({}) do |(name, schema), result|
        if !values.key?(name)
          error(:invalid_ir, "Required scope parameter is missing", path + [name]) if schema.fetch(:required)
        else
          result[name] = coerce(values[name], schema.fetch(:type), schema, path + [name])
        end
      end.freeze
    end

    def validate_joins(values)
      return invalid_collection("Joins", ["joins"]) unless values.is_a?(Array)
      error(:limit_exceeded, "Join limit exceeded", ["joins"], limit: @limits[:joins]) if values.length > @limits[:joins]
      values.each_with_index.filter_map do |value, index|
        unless value.is_a?(String) && value.split(".").length <= 2 && @snapshot.paths.include?("#{@root}.#{value}")
          error(:unregistered, "The requested association path is not registered", ["joins", index], resource: @root)
          next
        end
        QueryIR::Path.new(value)
      end
    end

    def validate_filters(values, joins)
      return invalid_collection("Filters", ["filters"]) unless values.is_a?(Array)
      values.each_with_index.filter_map do |value, index|
        unless value.is_a?(Hash) && value.keys.all? { |key| %w[field operator value].include?(key) } && value["field"].is_a?(String) && OPERATORS.include?(value["operator"])
          error(:invalid_ir, "Invalid filter", ["filters", index])
          next
        end
        field = resolve_field(value["field"], joins, ["filters", index, "field"])
        next unless field
        operator = value["operator"]
        if NULL_OPERATORS.include?(operator)
          error(:invalid_ir, "Null operator does not accept a value", ["filters", index, "value"]) if value.key?("value")
          error(:invalid_ir, "Null check is invalid for a non-null field", ["filters", index, "operator"]) unless field.null
          typed = nil
        else
          error(:invalid_ir, "Filter value is required", ["filters", index, "value"]) unless value.key?("value")
          if COMPARISON_OPERATORS.include?(operator) && !comparable_type?(field.type)
            error(:invalid_ir, "Operator is incompatible with field type", ["filters", index, "operator"])
          end
          typed = coerce_filter(value["value"], field, operator, ["filters", index, "value"])
        end
        QueryIR::Predicate.new(field: QueryIR::Path.new(value["field"]), operator: operator.to_sym, value: typed)
      end
    end

    def validate_sort(values, joins)
      return invalid_collection("Sort", ["sort"]) unless values.is_a?(Array)
      values.each_with_index.filter_map do |value, index|
        unless exact_hash?(value, %w[field direction]) && %w[asc desc].include?(value["direction"])
          error(:invalid_ir, "Invalid sort", ["sort", index])
          next
        end
        next unless resolve_field(value["field"], joins, ["sort", index, "field"])
        QueryIR::Sort.new(field: QueryIR::Path.new(value["field"]), direction: value["direction"].to_sym)
      end
    end

    def validate_limit(value)
      unless value.is_a?(Integer) && value.positive? && value <= @limits[:rows]
        error(:limit_exceeded, "Result limit exceeded", ["limit"], limit: @limits[:rows])
      end
      value
    end

    def validate_aggregate(operation, value, joins)
      if operation == "records"
        error(:invalid_ir, "Aggregate is only valid for aggregate operations", ["aggregate"]) if value
        return
      end
      unless value.is_a?(Hash) && value.keys.all? { |key| %w[function field].include?(key) } && value["function"].is_a?(String)
        error(:invalid_ir, "Aggregate is required", ["aggregate"])
        return
      end
      function = value["function"].to_sym
      permission = @resources.fetch(@root).aggregates[function]
      unless permission
        error(:unregistered, "The requested aggregate is not registered", ["aggregate", "function"], resource: @root)
        return
      end
      field_path = value["field"]
      if function == :count
        error(:invalid_ir, "Count does not accept a field", ["aggregate", "field"]) if field_path
      elsif !field_path || !resolve_field(field_path, joins, ["aggregate", "field"]) || permission != true && !permission.include?(field_path)
        error(:unregistered, "The aggregate field is not registered", ["aggregate", "field"], resource: @root)
        return
      end
      QueryIR::Aggregate.new(function: function, field: field_path && QueryIR::Path.new(field_path))
    end

    def resolve_field(path, joins, error_path)
      unless path.is_a?(String) && path.split(".").length <= 3
        error(:invalid_ir, "Invalid field path", error_path)
        return
      end
      segments = path.split(".")
      resource = @resources.fetch(@root)
      if segments.length > 1
        join = segments[0...-1].join(".")
        unless joins.any? { |item| item.to_s == join }
          error(:unregistered, "The field path is not joined", error_path, resource: @root)
          return
        end
        missing_association = false
        segments[0...-1].each do |association_name|
          association = resource.associations.find { |item| item.name == association_name }
          unless association
            error(:unregistered, "The field path is not registered", error_path, resource: @root)
            missing_association = true
            break
          end
          resource = @resources[association.resource]
        end
        return if missing_association
      end
      field = resource&.fields&.find { |candidate| candidate.name == segments.last }
      return field if field

      error(:unregistered, "The requested field is not registered", error_path, resource: @root)
      nil
    end

    def coerce_filter(value, field, operator, path)
      if ARRAY_OPERATORS.include?(operator)
        expected = (operator == "between") ? 2 : nil
        valid_array = value.is_a?(Array) && !value.empty?
        valid_array &&= value.length == expected if expected
        unless valid_array
          error(:invalid_ir, "Operator requires a bounded array", path)
          return
        end
        return value.map { |item| coerce(item, field.type, {enum_values: field.enum_values, nullable: field.null}, path) }.freeze
      end
      coerce(value, field.type, {enum_values: field.enum_values, nullable: field.null}, path)
    end

    def coerce(value, type, schema, path)
      if value.nil?
        error(:invalid_ir, "Null is not allowed", path) unless schema[:nullable]
        return QueryIR::Literal.new(value: nil, type: type)
      end
      if TIME_TYPES.include?(type.to_sym) && value.is_a?(Hash)
        relative = value["relative"]
        unless valid_relative_time?(value, relative)
          error(:invalid_ir, "Invalid relative time", path)
          return
        end
        return QueryIR::RelativeTime.new(amount: relative["amount"], unit: relative["unit"], direction: relative["direction"])
      end
      valid = case type.to_sym
      when :integer then value.is_a?(Integer)
      when :float, :decimal then value.is_a?(Numeric) && value.finite?
      when :boolean then [true, false].include?(value)
      when :date then value.is_a?(String) && Date.iso8601(value).to_s == value
      when :datetime, :timestamp, :time then valid_timestamp?(value)
      else value.is_a?(String)
      end
      enum_values = schema[:enum_values] || []
      valid &&= enum_values.include?(value) if enum_values.any?
      if schema[:minimum] && value.respond_to?(:<) then valid &&= value >= schema[:minimum] end
      if schema[:maximum] && value.respond_to?(:>) then valid &&= value <= schema[:maximum] end
      error(:invalid_ir, "Value is incompatible with the registered type", path) unless valid
      QueryIR::Literal.new(value: value, type: type)
    rescue ArgumentError
      error(:invalid_ir, "Value is incompatible with the registered type", path)
      QueryIR::Literal.new(value: value, type: type)
    end

    def valid_timestamp?(value)
      return false unless value.is_a?(String) && value.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)
      Time.iso8601(value)
      true
    rescue ArgumentError
      false
    end

    def valid_relative_time?(value, relative)
      exact_hash?(value, ["relative"]) &&
        exact_hash?(relative, %w[amount unit direction]) &&
        relative["amount"].is_a?(Integer) &&
        relative["amount"].positive? &&
        QueryIR::RelativeTime::UNITS.include?(relative["unit"]) &&
        QueryIR::RelativeTime::DIRECTIONS.include?(relative["direction"])
    end

    def comparable_type?(type) = NUMERIC_TYPES.include?(type.to_sym) || TIME_TYPES.include?(type.to_sym) || type.to_sym == :string
    def exact_hash?(value, keys) = value.is_a?(Hash) && value.keys.sort == keys.sort
    def invalid_collection(name, path) = error(:invalid_ir, "#{name} must be an array", path) && []
    def error(code, message, path, details = {}) = @errors << Error.new(code: code, message: message, path: path, details: details)
    def result = Result.new(ir: nil, errors: @errors, explanation: nil, snapshot: @snapshot)

    def explain(ir)
      parts = [(ir.operation == :records) ? "Select records from #{ir.root}" : "Aggregate #{ir.root} using #{ir.aggregate.function}"]
      parts << "apply scope #{ir.scopes.map(&:name).join(", ")}" if ir.scopes.any?
      parts << "filter #{ir.filters.map { |filter| "#{filter.field} #{filter.operator}" }.join(", ")}" if ir.filters.any?
      parts << "join #{ir.joins.join(", ")}" if ir.joins.any?
      parts << "sort #{ir.sort.map { |sort| "#{sort.field} #{sort.direction}" }.join(", ")}" if ir.sort.any?
      parts << "use distinct records" if ir.distinct
      parts << "limit #{ir.limit}"
      parts.join("; ")
    end
  end
end
