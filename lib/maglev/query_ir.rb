# frozen_string_literal: true

require "json"

module Maglev
  module QueryIR
    VERSION = 1

    module Value
      def to_json(*arguments)
        JSON.generate(to_h, *arguments)
      end
    end

    class Path
      include Value

      attr_reader :segments

      def initialize(value)
        @segments = value.to_s.split(".").map { |segment| segment.dup.freeze }.freeze
        freeze
      end

      def to_s = segments.join(".")
      def to_h = to_s
    end

    class Literal
      include Value

      attr_reader :value, :type

      def initialize(value:, type:)
        @value = value.freeze
        @type = type.to_sym
        freeze
      end

      def to_h = value
    end

    class RelativeTime
      include Value

      UNITS = %w[seconds minutes hours days weeks months years].freeze
      DIRECTIONS = %w[ago from_now].freeze
      attr_reader :amount, :unit, :direction

      def initialize(amount:, unit:, direction:)
        @amount = amount
        @unit = unit.to_s.freeze
        @direction = direction.to_s.freeze
        freeze
      end

      def to_h = {"relative" => {"amount" => amount, "unit" => unit, "direction" => direction}.freeze}.freeze
    end

    Predicate = Struct.new(:field, :operator, :value) do
      include Value

      def initialize(**attributes) = super.tap { freeze }

      def to_h
        result = {"field" => field.to_s, "operator" => operator.to_s}
        unless value.nil?
          result["value"] = if value.is_a?(Array)
            value.map { |item| item.respond_to?(:to_h) ? item.to_h : item }
          elsif value.respond_to?(:to_h)
            value.to_h
          else
            value
          end
        end
        result.freeze
      end
    end
    Scope = Struct.new(:name, :parameters) do
      include Value

      def initialize(**attributes)
        attributes[:parameters] = attributes.fetch(:parameters).freeze
        super
        freeze
      end

      def to_h = {"name" => name.to_s, "parameters" => parameters.transform_values { |value| value.respond_to?(:to_h) ? value.to_h : value }.freeze}.freeze
    end
    Sort = Struct.new(:field, :direction) do
      include Value

      def initialize(**attributes) = super.tap { freeze }
      def to_h = {"field" => field.to_s, "direction" => direction.to_s}.freeze
    end
    Aggregate = Struct.new(:function, :field) do
      include Value

      def initialize(**attributes) = super.tap { freeze }
      def to_h = {"function" => function.to_s}.tap { |hash| hash["field"] = field.to_s if field }.freeze
    end

    class Query
      include Value

      attr_reader :version, :root, :operation, :scopes, :filters, :joins, :sort, :distinct, :limit, :aggregate

      def initialize(version:, root:, operation:, scopes:, filters:, joins:, sort:, distinct:, limit:, aggregate: nil)
        @version = version
        @root = root.to_s.freeze
        @operation = operation.to_sym
        @scopes = scopes.freeze
        @filters = filters.freeze
        @joins = joins.freeze
        @sort = sort.freeze
        @distinct = distinct
        @limit = limit
        @aggregate = aggregate
        freeze
      end

      def to_h
        hash = {"version" => version, "root" => root, "operation" => operation.to_s,
                "scopes" => scopes.map(&:to_h), "filters" => filters.map(&:to_h),
                "joins" => joins.map(&:to_s), "sort" => sort.map(&:to_h),
                "distinct" => distinct, "limit" => limit}
        hash["aggregate"] = aggregate.to_h if aggregate
        hash.freeze
      end
    end

    def self.from_json(json)
      data = JSON.parse(json)
      Query.new(version: data.fetch("version"), root: data.fetch("root"), operation: data.fetch("operation"),
        scopes: data.fetch("scopes").map { |scope| Scope.new(name: scope.fetch("name"), parameters: scope.fetch("parameters")) },
        filters: data.fetch("filters").map { |filter| Predicate.new(field: Path.new(filter.fetch("field")), operator: filter.fetch("operator").to_sym, value: filter["value"]) },
        joins: data.fetch("joins").map { |path| Path.new(path) },
        sort: data.fetch("sort").map { |sort| Sort.new(field: Path.new(sort.fetch("field")), direction: sort.fetch("direction").to_sym) },
        distinct: data.fetch("distinct"), limit: data.fetch("limit"),
        aggregate: data["aggregate"] && Aggregate.new(function: data.dig("aggregate", "function").to_sym, field: data.dig("aggregate", "field") && Path.new(data.dig("aggregate", "field"))))
    end
  end
end
