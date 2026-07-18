# frozen_string_literal: true

module Maglev
  class StructuredEvidence
    State = Struct.new(:loaded, :records, :count, :truncated)

    attr_reader :scalar, :filters, :date_ranges

    def initialize(records: [], scalar: nil, filters: [], date_ranges: [], count: 0, truncated: false, loader: nil)
      materialized = deep_freeze(records)
      @state = State.new(loader.nil?, materialized, count, truncated)
      @loader = loader
      @materialization_lock = Mutex.new
      @scalar = deep_freeze(scalar)
      @filters = filters.map { |filter| deep_freeze(filter) }.freeze
      @date_ranges = date_ranges.map { |range| deep_freeze(range) }.freeze
      freeze
    end

    def records
      materialize.records
    end

    def count
      materialize.count
    end

    def truncated
      materialize.truncated
    end

    def truncated? = truncated

    private

    def materialize
      return @state if @state.loaded

      @materialization_lock.synchronize do
        return @state if @state.loaded

        records, count, truncated = @loader.call
        @state.records = deep_freeze(records)
        @state.count = count
        @state.truncated = truncated
        @state.loaded = true
      end
      @state
    end

    def deep_freeze(value)
      case value
      when Hash then value.to_h { |key, item| [deep_freeze(key), deep_freeze(item)] }.freeze
      when Array then value.map { |item| deep_freeze(item) }.freeze
      else value.frozen? ? value : value.freeze
      end
    end
  end

  class StructuredResult
    STATUSES = %i[succeeded clarification_required unsupported failed].freeze
    KINDS = %i[relation scalar aggregate none].freeze

    attr_reader :status, :route, :kind, :value, :evidence, :interpretation, :warnings, :plan, :trace_id

    def initialize(status:, kind:, plan:, trace_id:, value: nil, evidence: StructuredEvidence.new,
      interpretation: nil, warnings: [])
      raise ArgumentError, "invalid structured result status" unless STATUSES.include?(status)
      raise ArgumentError, "invalid structured result kind" unless KINDS.include?(kind)
      raise ArgumentError, "only successful results may carry a value" if status != :succeeded && !value.nil?

      @status = status
      @route = :structured
      @kind = kind
      @value = value
      @evidence = evidence
      @interpretation = interpretation&.to_s&.freeze
      @warnings = Array(warnings).map { |warning| warning.to_s.freeze }.freeze
      @plan = plan
      @trace_id = trace_id.to_s.freeze
      freeze
    end

    def render
      return warnings.first || "The request is unsupported." if status == :unsupported
      return plan.clarification.fetch(:message) if status == :clarification_required
      return "The structured request failed." if status == :failed
      return "Count: #{value}" if kind == :aggregate && plan.ir.aggregate.function == :count
      return "#{plan.ir.aggregate.function.to_s.capitalize}: #{value}" if kind == :aggregate

      return "No matching records." if evidence.records.empty?

      headings = evidence.records.first.keys
      ([headings.join(" | ")] + evidence.records.map { |record| headings.map { |heading| record[heading] }.join(" | ") }).join("\n")
    end
  end
end
