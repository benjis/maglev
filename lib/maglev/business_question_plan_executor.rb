# frozen_string_literal: true

require "securerandom"
require "timeout"

module Maglev
  class BusinessQuestionStepState
    attr_reader :step_id, :status, :limitation

    def initialize(step_id:, status:, limitation: nil)
      @step_id = step_id.to_s.freeze
      @status = status.to_sym
      @limitation = limitation&.to_s&.freeze
      freeze
    end
  end

  class BusinessQuestionEvidence
    attr_reader :step_id, :kind, :resource, :dependencies, :value

    def initialize(step:, value:)
      @step_id = step.id
      @kind = step.expected_evidence.fetch("kind").to_sym
      @resource = step.resource
      @dependencies = step.depends_on
      @value = BusinessQuestionPlan.deep_freeze(value)
      freeze
    end
  end

  class BusinessQuestionExecution
    attr_reader :status, :evidence, :step_states, :limitations, :trace_id

    def initialize(status:, evidence:, step_states:, limitations:, trace_id:)
      @status = status
      @evidence = evidence.freeze
      @step_states = step_states.freeze
      @limitations = limitations.freeze
      @trace_id = trace_id.to_s.freeze
      freeze
    end
  end

  class BusinessQuestionPlanExecutor
    def initialize(structured_runner:, knowledge_runner:, max_concurrency: 1, step_timeout: nil)
      unless max_concurrency.is_a?(Integer) && max_concurrency.positive?
        raise ArgumentError, "max_concurrency must be a positive Integer"
      end
      if !step_timeout.nil? && (!step_timeout.is_a?(Numeric) || !step_timeout.positive?)
        raise ArgumentError, "step_timeout must be positive"
      end

      @structured_runner = structured_runner
      @knowledge_runner = knowledge_runner
      @max_concurrency = max_concurrency
      @step_timeout = step_timeout
    end

    def execute(plan, cancellation: nil)
      unless plan.is_a?(BusinessQuestionPlan) && plan.validated?
        raise PlanValidationError, "A validated Business Question Plan is required"
      end
      if cancellation && !cancellation.respond_to?(:call)
        raise ArgumentError, "cancellation must respond to #call"
      end

      values = {}
      states = {}
      remaining = plan.steps.dup
      running = {}
      completed = []
      completion_lock = Mutex.new
      completion_signal = ConditionVariable.new
      until states.size == plan.steps.size
        if cancellation&.call
          (remaining + running.values.map(&:first)).each do |step|
            states[step.id] = BusinessQuestionStepState.new(
              step_id: step.id, status: :cancelled, limitation: "Step #{step.id} cancelled"
            )
          end
          running.each_value { |_, thread| thread.kill }
          running.each_value { |_, thread| thread.join }
          remaining.clear
          running.clear
          break
        end

        blocked = remaining.select do |step|
          step.depends_on.any? { |id| states.key?(id) && states.fetch(id).status != :succeeded }
        end
        blocked.each do |step|
          failed_dependencies = step.depends_on.select { |id| states.fetch(id, nil)&.status != :succeeded }
          states[step.id] = BusinessQuestionStepState.new(
            step_id: step.id,
            status: :blocked,
            limitation: "Step #{step.id} blocked by failed dependency: #{failed_dependencies.join(", ")}"
          )
        end
        remaining -= blocked
        while running.size < @max_concurrency
          step = remaining.find do |candidate|
            candidate.depends_on.all? { |id| states.key?(id) && states.fetch(id).status == :succeeded }
          end
          break unless step

          remaining.delete(step)
          dependency_values = step.depends_on.map { |id| values.fetch(id) }.freeze
          thread = start_step(step, dependency_values, completed, completion_lock, completion_signal)
          running[step.id] = [step, thread]
        end

        completion_lock.synchronize do
          completion_signal.wait(completion_lock, 0.01) if completed.empty? && running.any?
        end
        completion_lock.synchronize { completed.shift(completed.length) }.each do |step, status, evidence, limitation|
          _, thread = running.delete(step.id)
          thread.join
          values[step.id] = evidence if status == :succeeded
          states[step.id] = BusinessQuestionStepState.new(
            step_id: step.id, status: status, limitation: limitation
          )
        end
      end
      evidence = plan.steps.filter_map do |step|
        next unless states.fetch(step.id).status == :succeeded

        values.fetch(step.id)
      end
      step_states = plan.steps.map { |step| states.fetch(step.id) }
      limitations = step_states.filter_map(&:limitation)
      status = if step_states.all? { |state| state.status == :succeeded }
        :complete
      elsif evidence.empty?
        :failed
      else
        :partial
      end
      BusinessQuestionExecution.new(status: status, evidence: evidence, step_states: step_states,
        limitations: limitations, trace_id: SecureRandom.uuid)
    end

    private

    def start_step(step, dependency_values, completed, completion_lock, completion_signal)
      Thread.new(step) do |scheduled_step|
        result = execute_step(scheduled_step, dependency_values)
        completion_lock.synchronize do
          completed << result
          completion_signal.signal
        end
      end
    end

    def execute_step(step, dependency_values)
      value = Timeout.timeout(@step_timeout) do
        case step.kind
        when :structured then @structured_runner.call(step)
        when :knowledge then @knowledge_runner.call(step)
        when :hybrid then dependency_values
        end
      end
      unless compatible_evidence?(step, value)
        return [step, :failed, nil, "Step #{step.id} produced incompatible Evidence"]
      end

      [step, :succeeded, BusinessQuestionEvidence.new(step: step, value: value), nil]
    rescue Timeout::Error
      [step, :timed_out, nil, "Step #{step.id} timed out"]
    rescue => error
      [step, :failed, nil, "Step #{step.id} failed: #{error.class}"]
    end

    def compatible_evidence?(step, value)
      case step.expected_evidence.fetch("kind")
      when "records", "aggregate"
        value.is_a?(StructuredEvidence)
      when "semantic_matches"
        value.is_a?(KnowledgeEvidence)
      when "hybrid"
        value.is_a?(Array) && value.length == step.depends_on.length &&
          value.each_with_index.all? do |evidence, index|
            evidence.is_a?(BusinessQuestionEvidence) &&
              evidence.kind.to_s == step.dependency_types.fetch(step.depends_on.fetch(index))
          end
      end
    end
  end
end
