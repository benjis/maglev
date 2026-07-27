# frozen_string_literal: true

module Maglev
  class BusinessQuestionPlan
    VERSION = 1
    STEP_KINDS = %i[structured knowledge hybrid].freeze
    ROOT_KEYS = %w[version steps].freeze
    SERIALIZED_ROOT_KEYS = %w[version budgets steps].freeze
    STEP_KEYS = %w[id kind resource depends_on dependency_types input].freeze
    SERIALIZED_STEP_KEYS = %w[id kind resource depends_on dependency_types input expected_evidence].freeze
    LIMIT_KEYS = %i[steps depth resources retrieval_size structured_result_size total_work].freeze

    Step = Struct.new(:id, :kind, :resource, :depends_on, :dependency_types, :input, :expected_evidence) do
      def initialize(**attributes)
        attributes[:id] = attributes.fetch(:id).to_s.freeze
        attributes[:kind] = attributes.fetch(:kind).to_sym
        attributes[:resource] = attributes.fetch(:resource).to_s.freeze
        attributes[:depends_on] = attributes.fetch(:depends_on).map { |id| id.to_s.freeze }.freeze
        attributes[:dependency_types] = BusinessQuestionPlan.deep_freeze(attributes.fetch(:dependency_types))
        attributes[:input] = BusinessQuestionPlan.deep_freeze(attributes.fetch(:input))
        attributes[:expected_evidence] = BusinessQuestionPlan.deep_freeze(attributes.fetch(:expected_evidence))
        super
        freeze
      end

      def to_h
        BusinessQuestionPlan.deep_freeze(
          "id" => id,
          "kind" => kind.to_s,
          "resource" => resource,
          "depends_on" => depends_on,
          "dependency_types" => dependency_types,
          "input" => input,
          "expected_evidence" => expected_evidence
        )
      end
    end

    attr_reader :version, :steps, :limits, :budgets

    def self.build(input, authorized_resources:, limits:)
      new(input, authorized_resources: authorized_resources, limits: limits, validated: false)
    end

    def self.validated_build(input, authorized_resources:, limits:)
      new(input, authorized_resources: authorized_resources, limits: limits, validated: true)
    end
    private_class_method :validated_build

    def self.deep_freeze(value)
      case value
      when Hash
        value.to_h { |key, item| [deep_freeze(key), deep_freeze(item)] }.freeze
      when Array
        value.map { |item| deep_freeze(item) }.freeze
      else
        value.frozen? ? value : value.freeze
      end
    end

    def initialize(input, authorized_resources:, limits:, validated:)
      @limits = normalize_limits(limits)
      validate_root!(input)
      @version = input.fetch("version")
      @budgets = self.class.deep_freeze(@limits.transform_keys(&:to_s))
      validate_serialized_budgets!(input["budgets"]) if input.key?("budgets")
      @steps = build_steps(input.fetch("steps"))
      validate_graph!(Array(authorized_resources).map(&:to_s))
      @validated = validated
      freeze
    end

    def validated? = @validated

    def execution_order
      ordered = []
      remaining = steps.to_h { |step| [step.id, step] }
      until remaining.empty?
        ready = remaining.values.select { |step| (step.depends_on - ordered.map(&:id)).empty? }
        raise PlanValidationError, "Business Question Plan contains a cycle" if ready.empty?

        ready.each do |step|
          ordered << step
          remaining.delete(step.id)
        end
      end
      ordered.freeze
    end

    def to_h
      self.class.deep_freeze("version" => version, "budgets" => budgets, "steps" => steps.map(&:to_h))
    end

    private

    def normalize_limits(values)
      values = values.transform_keys(&:to_sym)
      unless values.keys.sort == LIMIT_KEYS.sort &&
          values.values.all? { |value| value.is_a?(Integer) && value.positive? }
        raise ArgumentError, "invalid Business Question Plan limits"
      end
      values.freeze
    end

    def validate_root!(input)
      valid_keys = [ROOT_KEYS.sort, SERIALIZED_ROOT_KEYS.sort].include?(input.keys.sort) if input.is_a?(Hash)
      unless input.is_a?(Hash) && valid_keys && input["version"] == VERSION &&
          input["steps"].is_a?(Array) && !input["steps"].empty?
        raise PlanValidationError, "Invalid Business Question Plan"
      end
      raise PlanValidationError, "Business Question Plan step limit exceeded" if input["steps"].size > limits[:steps]
    end

    def build_steps(values)
      values.map do |value|
        valid_keys = [STEP_KEYS.sort, SERIALIZED_STEP_KEYS.sort].include?(value.keys.sort) if value.is_a?(Hash)
        unless value.is_a?(Hash) && valid_keys &&
            value["id"].is_a?(String) && !value["id"].empty? &&
            value["kind"].is_a?(String) && STEP_KINDS.include?(value["kind"].to_sym) &&
            value["resource"].is_a?(String) && !value["resource"].empty? &&
            value["depends_on"].is_a?(Array) && value["depends_on"].all? { |id| id.is_a?(String) } &&
            value["dependency_types"].is_a?(Hash) &&
            value["dependency_types"].keys.sort == value["depends_on"].sort &&
            value["dependency_types"].values.all? { |kind| kind.is_a?(String) } &&
            value["input"].is_a?(Hash)
          raise PlanValidationError, "Invalid Business Question Plan step"
        end
        expected_evidence = expected_evidence_for(value)
        if value.key?("expected_evidence") && value["expected_evidence"] != expected_evidence
          raise PlanValidationError, "Invalid Business Question Plan expected evidence"
        end
        Step.new(id: value["id"], kind: value["kind"], resource: value["resource"],
          depends_on: value["depends_on"], dependency_types: value["dependency_types"],
          input: value["input"], expected_evidence: expected_evidence)
      end.freeze
    end

    def validate_serialized_budgets!(values)
      unless values.is_a?(Hash) && values == @limits.transform_keys(&:to_s)
        raise PlanValidationError, "Invalid Business Question Plan budgets"
      end
    end

    def expected_evidence_for(value)
      kind = value.fetch("kind")
      input = value.fetch("input")
      maximum = case kind
      when "structured" then input.fetch("ir", {}).fetch("limit", 1)
      when "knowledge"
        retrieval = input.fetch("retrieval", {})
        retrieval.fetch("limit", 1) * retrieval.fetch("chunks_per_owner", 1)
      when "hybrid" then value.fetch("depends_on").size
      end
      evidence_kind = case kind
      when "structured" then (input.dig("ir", "operation") == "records") ? "records" : "aggregate"
      when "knowledge" then "semantic_matches"
      when "hybrid" then "hybrid"
      end
      {"kind" => evidence_kind, "maximum" => maximum}
    rescue TypeError
      raise PlanValidationError, "Invalid Business Question Plan expected evidence"
    end

    def validate_graph!(authorized_resources)
      ids = steps.map(&:id)
      raise PlanValidationError, "Business Question Plan step ids must be unique" unless ids.uniq == ids
      raise PlanValidationError, "Business Question Plan references an unauthorized resource" unless
        (steps.map(&:resource).uniq - authorized_resources).empty?
      raise PlanValidationError, "Business Question Plan resource limit exceeded" if
        steps.map(&:resource).uniq.size > limits[:resources]
      raise PlanValidationError, "Business Question Plan contains an invalid dependency" unless
        steps.all? { |step| step.depends_on.uniq == step.depends_on && (step.depends_on - ids).empty? && !step.depends_on.include?(step.id) }

      order = execution_order
      depths = {}
      order.each { |step| depths[step.id] = 1 + step.depends_on.map { |id| depths.fetch(id) }.max.to_i }
      raise PlanValidationError, "Business Question Plan depth limit exceeded" if depths.values.max > limits[:depth]
      validate_work_limits!
    end

    def validate_work_limits!
      retrieval_values = steps.select { |step| step.kind == :knowledge }
        .map do |step|
          retrieval = step.input.fetch("retrieval", {})
          retrieval.fetch("limit", 1) * retrieval.fetch("chunks_per_owner", 1)
        end
      structured_values = steps.select { |step| step.kind == :structured }
        .map { |step| step.input.fetch("ir", {}).fetch("limit", 1) }
      unless retrieval_values.all? { |value| value.is_a?(Integer) && value.positive? }
        raise PlanValidationError, "Business Question Plan retrieval limit exceeded"
      end
      unless structured_values.all? { |value| value.is_a?(Integer) && value.positive? }
        raise PlanValidationError, "Business Question Plan structured result limit exceeded"
      end

      retrieval = retrieval_values.sum
      structured = structured_values.sum
      unless retrieval <= limits[:retrieval_size]
        raise PlanValidationError, "Business Question Plan retrieval limit exceeded"
      end
      unless structured <= limits[:structured_result_size]
        raise PlanValidationError, "Business Question Plan structured result limit exceeded"
      end
      raise PlanValidationError, "Business Question Plan total work limit exceeded" if
        steps.size + retrieval + structured > limits[:total_work]
    end
  end
end
