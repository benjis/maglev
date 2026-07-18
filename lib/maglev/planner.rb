# frozen_string_literal: true

require "securerandom"

require_relative "planner_adapter"
require_relative "query_validator"
require_relative "trace"

module Maglev
  class Planner
    QUERY_IR_SCHEMA = {
      type: "object", additionalProperties: false,
      required: %w[version root operation scopes filters joins sort distinct limit],
      properties: {
        version: {const: 1}, root: {type: "string"}, operation: {enum: %w[records aggregate]},
        scopes: {type: "array", items: {type: "object", additionalProperties: false,
                                        required: %w[name parameters], properties: {name: {type: "string"}, parameters: {type: "object"}}}},
        filters: {type: "array", items: {type: "object", additionalProperties: false,
                                         required: %w[field operator value], properties: {field: {type: "string"}, operator: {type: "string"}, value: {}}}},
        joins: {type: "array", items: {type: "string"}},
        sort: {type: "array", items: {type: "object", additionalProperties: false,
                                      required: %w[field direction], properties: {field: {type: "string"}, direction: {enum: %w[asc desc]}}}},
        distinct: {type: "boolean"}, limit: {type: "integer", minimum: 1},
        aggregate: {type: ["object", "null"]}
      }
    }.freeze
    OUTCOMES = %w[ready clarification_required unsupported].freeze

    Plan = Struct.new(:status, :route, :ir, :resource, :explanation, :warnings, :errors,
      :clarification, :constraints, :trace_id, :validation, :base_relation,
      :evidence_requirements, :policy_limits) do
      def initialize(**attributes)
        attributes[:status] = attributes.fetch(:status).to_sym
        attributes[:route] = (attributes[:route] || :structured).to_sym
        attributes[:warnings] = Array(attributes[:warnings]).freeze
        attributes[:errors] = Array(attributes[:errors]).freeze
        attributes[:constraints] = (attributes[:constraints] || {}).freeze
        attributes[:evidence_requirements] = (attributes[:evidence_requirements] || {}).freeze
        attributes[:policy_limits] = (attributes[:policy_limits] || {}).freeze
        attributes[:clarification] = attributes[:clarification]&.freeze
        super
        freeze
      end

      def ready? = status == :ready
    end

    def initialize(adapter:)
      unless adapter.respond_to?(:plan)
        raise ConfigurationError, "planner adapter must implement #plan"
      end

      @adapter = adapter
    end

    def plan(question:, snapshot:, resource:, constraints: {}, base_relation: nil)
      root = resource.to_s
      trace_id = SecureRandom.uuid
      request_constraints = normalize_constraints(constraints)
      output = Trace.instrument(:planning, trace_id: trace_id, resource: root) do |payload|
        provider_plan(question, snapshot, request_constraints, nil).tap do |result|
          payload[:status] = result.is_a?(Hash) ? result["status"]&.to_sym || :invalid : :invalid
        end
      end
      return outcome_plan(output, root, request_constraints, trace_id) unless output.is_a?(Hash) && output["status"] == "ready"

      validation = Trace.instrument(:validation, trace_id: trace_id, resource: root,
        operation: output.dig("ir", "operation")) do |payload|
        validate(output["ir"], snapshot, root, request_constraints).tap do |result|
          payload[:status] = result.valid? ? :ready : :invalid
          payload[:error_codes] = result.errors.map(&:code).uniq.sort if result.errors.any?
        end
      end
      unless validation.valid?
        repair = {errors: safe_errors(validation.errors)}.freeze
        output = Trace.instrument(:planning, trace_id: trace_id, resource: root) do |payload|
          provider_plan(question, snapshot, request_constraints, repair).tap do |result|
            payload[:status] = result.is_a?(Hash) ? result["status"]&.to_sym || :invalid : :invalid
          end
        end
        return outcome_plan(output, root, request_constraints, trace_id) unless output.is_a?(Hash) && output["status"] == "ready"
        validation = Trace.instrument(:validation, trace_id: trace_id, resource: root,
          operation: output.dig("ir", "operation")) do |payload|
          validate(output["ir"], snapshot, root, request_constraints).tap do |result|
            payload[:status] = result.valid? ? :ready : :invalid
            payload[:error_codes] = result.errors.map(&:code).uniq.sort if result.errors.any?
          end
        end
      end

      return invalid_plan(root, request_constraints, validation.errors, trace_id) unless validation.valid?

      evidence_requirements = {kind: validation.ir.operation, max_rows: validation.ir.limit}.freeze
      Plan.new(status: :ready, ir: validation.ir, resource: root, explanation: validation.explanation,
        validation: validation, constraints: request_constraints, trace_id: trace_id,
        base_relation: base_relation, evidence_requirements: evidence_requirements,
        policy_limits: validator_limits(snapshot, root, request_constraints))
    end

    private

    def provider_plan(question, snapshot, constraints, repair)
      @adapter.plan(question: question.to_s, schema_snapshot: snapshot, constraints: constraints,
        query_ir_schema: QUERY_IR_SCHEMA, repair: repair)
    end

    def validate(input, snapshot, root, constraints)
      QueryValidator.new(snapshot: snapshot, root: root, limits: constraints).call(input)
    end

    def validator_limits(snapshot, root, constraints)
      QueryValidator.new(snapshot: snapshot, root: root, limits: constraints).policy_limits
    end

    def normalize_constraints(constraints)
      values = constraints.transform_keys(&:to_sym)
      allowed = QueryValidator::DEFAULT_LIMITS.keys
      unless (values.keys - allowed).empty? && values.values.all? { |value| value.is_a?(Integer) && value.positive? }
        raise ArgumentError, "invalid planner constraints"
      end
      values.freeze
    end

    def safe_errors(errors)
      errors.map { |error| {code: error.code, message: error.message, path: error.path}.freeze }.freeze
    end

    def outcome_plan(output, root, constraints, trace_id)
      return invalid_plan(root, constraints, [], trace_id) unless output.is_a?(Hash) && OUTCOMES.include?(output["status"])

      status = output["status"].to_sym
      case status
      when :clarification_required
        message = output["message"]
        choices = output["choices"]
        return invalid_plan(root, constraints, [], trace_id) unless message.is_a?(String) && choices.is_a?(Array) &&
          choices.length.between?(1, 10) && choices.all? { |choice| choice.is_a?(String) && choice.bytesize <= 200 }
        Plan.new(status: status, resource: root, clarification: {message: message, choices: choices.freeze},
          constraints: constraints, trace_id: trace_id)
      when :unsupported
        return invalid_plan(root, constraints, [], trace_id) unless output["message"].is_a?(String)
        Plan.new(status: status, resource: root, warnings: [output["message"]], constraints: constraints,
          trace_id: trace_id)
      else
        invalid_plan(root, constraints, [], trace_id)
      end
    end

    def invalid_plan(root, constraints, errors, trace_id)
      Plan.new(status: :invalid, resource: root, errors: errors, constraints: constraints,
        trace_id: trace_id)
    end
  end

  def self.plan(question, resource:, base_relation:, resources: nil, constraints: {}, user: nil,
    authorizer: nil, adapter: Maglev.configuration.planner_adapter)
    raise ConfigurationError, "planner adapter is not configured" unless adapter
    unless defined?(ActiveRecord::Relation) && base_relation.is_a?(ActiveRecord::Relation)
      raise ConfigurationError, "an ActiveRecord base relation is required for planning"
    end

    identifiers = [resource, *Array(resources)].compact.map(&:to_s).uniq
    snapshot = Registry.snapshot(resources: identifiers, user: user, authorizer: authorizer)
    root_model = snapshot.model_class_for(resource)
    unless root_model && base_relation.klass == root_model
      raise ConfigurationError, "base relation does not match the authorized resource"
    end

    Planner.new(adapter: adapter).plan(question: question, snapshot: snapshot,
      resource: resource, constraints: constraints, base_relation: base_relation)
  end
end
