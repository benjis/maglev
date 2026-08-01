# frozen_string_literal: true

require "json"
require "securerandom"

module Maglev
  class BusinessQuestionEngine
    MAX_PLANNING_FACT_BYTES = 4_096
    SAFE_FAILURE_WARNING = "The question could not be answered safely."

    def initialize(policy_resolver: Maglev.configuration.policy_resolver,
      planner_adapter: Maglev.configuration.planner_adapter,
      resource_selector_adapter: Maglev.configuration.resource_selector_adapter)
      @policy_resolver = policy_resolver
      @planner_adapter = planner_adapter
      @resource_selector_adapter = resource_selector_adapter
    end

    def ask(question, user:, context:, continuation: nil)
      trace_id = nil
      authorized = resolve_authorized_resources(user, context)
      semantic_context = authorized_semantic_context(authorized)
      binding = continuation_binding(user, context, authorized)
      if continuation
        question, selection = ContinuationToken.new.consume(continuation, binding: binding) do |state|
          resume_clarification(question, state, authorized)
        end
        if selection.nil?
          semantic = interpret_semantics(question, semantic_context, binding)
          return semantic if semantic.is_a?(BusinessOutcome)
          return execute_semantic_ir(semantic, authorized, semantic_context) if semantic&.status == :compiled

          selection = select_resources(question, authorized, binding: binding, semantic_context: semantic_context)
        end
      else
        semantic = interpret_semantics(question, semantic_context, binding)
        return semantic if semantic.is_a?(BusinessOutcome)
        return execute_semantic_ir(semantic, authorized, semantic_context) if semantic&.status == :compiled

        selection = select_resources(question, authorized, binding: binding, semantic_context: semantic_context)
      end
      return selection if selection.is_a?(BusinessOutcome)

      selected = selection.map { |identifier| authorized.fetch(identifier) }
      snapshot = Registry.snapshot(resources: selection,
        authorizer: ->(*) { true },
        limits: {
          resources: Maglev.configuration.selected_resource_max_count,
          bytes: Maglev.configuration.selected_schema_max_bytes
        })
      return execute_business_plan(question, selected, snapshot, semantic_context) if selection.length > 1

      root = selected.first
      plan = Planner.new(adapter: configured_planner).plan(
        question: question,
        snapshot: snapshot,
        resource: root.fetch(:identifier),
        base_relation: root.fetch(:base_relation),
        planning_facts: root.fetch(:planning_facts),
        semantic_context: semantic_context&.provider_payload
      )
      trace_id = plan.trace_id
      if plan.status == :clarification_required
        if continuation
          return BusinessOutcome.new(status: :unsupported, trace_id: plan.trace_id,
            warnings: ["The clarification did not resolve the ambiguity."],
            semantic_grounding: semantic_grounding(semantic_context))
        end
        return planning_clarification_outcome(plan, question, selection, binding, semantic_context)
      end
      result = if plan.route == :knowledge
        KnowledgeExecutor.new.execute(plan, question: question)
      else
        Maglev.execute(plan)
      end
      outcome_for(result, semantic_context)
    rescue
      BusinessOutcome.new(status: :failed, trace_id: trace_id || SecureRandom.uuid,
        warnings: [SAFE_FAILURE_WARNING],
        semantic_grounding: SemanticGrounding.minimal(semantic_context))
    end

    private

    def execute_business_plan(question, selected, snapshot, semantic_context)
      authorized = selected.to_h do |resource|
        entry = Registry.fetch(resource.fetch(:identifier))
        [entry.identifier, {structured: !entry.queryable.nil?, knowledge: !entry.knowledge.nil?}]
      end
      limits = business_plan_limits
      plan = BusinessQuestionPlanner.new(adapter: configured_planner, snapshot: snapshot,
        authorized_resources: authorized, limits: limits).plan(
          question: question,
          planning_facts: selected.to_h { |resource| [resource.fetch(:identifier), resource.fetch(:planning_facts)] },
          semantic_context: semantic_context&.provider_payload
        )
      relations = selected.to_h { |resource| [resource.fetch(:identifier), resource.fetch(:base_relation)] }
      execution = BusinessQuestionPlanExecutor.new(
        structured_runner: ->(step) { execute_structured_step(step, snapshot, relations) },
        knowledge_runner: ->(step) { execute_knowledge_step(step, relations, question) },
        max_concurrency: Maglev.configuration.business_plan_max_concurrency,
        step_timeout: Maglev.configuration.business_plan_step_timeout
      ).execute(plan)
      status = {complete: :answered, partial: :partial, failed: :failed}.fetch(execution.status)
      synthesis = synthesize_business_outcome(question, execution, semantic_context)
      answer = synthesis[:answer] if status == :answered
      BusinessOutcome.new(status: status, answer: answer, evidence: execution.evidence,
        findings: synthesis[:findings], inferences: synthesis[:inferences],
        recommendations: synthesis[:recommendations], assumptions: synthesis[:assumptions],
        limitations: synthesis[:limitations], trace_id: execution.trace_id,
        semantic_grounding: grounding_for_status(status, semantic_context))
    end

    def business_plan_limits
      {
        steps: Maglev.configuration.business_plan_max_steps,
        depth: Maglev.configuration.business_plan_max_depth,
        resources: Maglev.configuration.selected_resource_max_count,
        retrieval_size: Maglev.configuration.business_plan_max_retrieval_size,
        structured_result_size: Maglev.configuration.business_plan_max_structured_result_size,
        total_work: Maglev.configuration.business_plan_max_total_work
      }.freeze
    end

    def synthesize_business_outcome(question, execution, semantic_context)
      adapter = Maglev.configuration.outcome_synthesis_adapter
      unless adapter
        return {
          answer: nil, findings: [], inferences: [], recommendations: [], assumptions: [],
          limitations: execution.limitations
        }
      end

      BusinessOutcomeSynthesizer.new(adapter: adapter).synthesize(
        question: question, execution: execution, semantic_context: semantic_context&.provider_payload
      )
    end

    def execute_structured_step(step, snapshot, relations)
      validation = QueryValidator.new(snapshot: snapshot, root: step.resource,
        limits: {rows: Maglev.configuration.business_plan_max_structured_result_size}).call(step.input.fetch("ir"))
      raise PlanValidationError, "Structured step was not validated" unless validation.valid?

      plan = Planner::Plan.new(status: :ready, resource: step.resource, ir: validation.ir,
        explanation: validation.explanation, validation: validation,
        base_relation: relations.fetch(step.resource), trace_id: SecureRandom.uuid)
      result = Maglev.execute(plan)
      raise Error, "Business Question Plan structured step failed" unless result.status == :succeeded

      result.evidence
    end

    def execute_knowledge_step(step, relations, question)
      retrieval = step.input.fetch("retrieval").transform_keys(&:to_sym).freeze
      plan = Planner::Plan.new(status: :ready, route: :knowledge, resource: step.resource,
        retrieval: retrieval, base_relation: relations.fetch(step.resource), trace_id: SecureRandom.uuid)
      KnowledgeRetriever.new.retrieve(plan, question: question)
    end

    def configured_planner
      @planner_adapter || raise(ConfigurationError, "planner adapter is not configured")
    end

    def resolve_authorized_resources(user, context)
      unless @policy_resolver&.respond_to?(:call)
        raise ConfigurationError, "policy resolver is not configured"
      end

      resolution = @policy_resolver.call(user: user, context: context)
      raise ConfigurationError, "policy resolver must return a Hash" unless resolution.is_a?(Hash)

      authorized = resolution.filter_map do |identifier, value|
        entry = Registry.fetch(identifier)
        next if entry.nil? || (!entry.queryable && !entry.knowledge)
        next unless value.is_a?(Hash)

        relation = value[:base_relation] || value["base_relation"]
        next unless defined?(ActiveRecord::Relation) && relation.is_a?(ActiveRecord::Relation)
        next unless relation.klass == entry.model_class

        facts = value[:planning_facts] || value["planning_facts"] || {}
        validate_planning_facts!(facts)
        {identifier: entry.identifier, base_relation: relation, planning_facts: deep_freeze(facts)}
      end
      raise ConfigurationError, "at least one authorized queryable resource is required" if authorized.empty?

      authorized.to_h { |resource| [resource.fetch(:identifier), resource] }.freeze
    end

    def select_resources(question, authorized, binding:, semantic_context:)
      catalog = ResourceCatalog.new.build(authorized.keys)
      raise ConfigurationError, "authorized resource catalog is empty" if catalog.empty?
      return [catalog.first.fetch(:identifier)].freeze if catalog.one?
      unless @resource_selector_adapter&.respond_to?(:select)
        raise ConfigurationError, "resource selector adapter is not configured"
      end

      request = {question: question.to_s, catalog: catalog}
      request[:semantic_context] = semantic_context.provider_payload if semantic_context
      output = @resource_selector_adapter.select(**request)
      raise PermanentProviderError, "Resource selector returned invalid output" unless output.is_a?(Hash)

      case output["status"]
      when "selected"
        validate_selection(output["resources"], catalog, authorized)
      when "unsupported"
        selection_outcome(:unsupported, output, semantic_context: semantic_context)
      when "clarification_required"
        selection_outcome(:clarification_required, output, catalog: catalog, question: question,
          binding: binding, semantic_context: semantic_context)
      else
        raise PermanentProviderError, "Resource selector returned invalid output"
      end
    end

    def validate_selection(resources, catalog, authorized)
      unless resources.is_a?(Array) &&
          resources.length.between?(1, Maglev.configuration.selected_resource_max_count)
        raise PermanentProviderError, "Resource selector returned invalid output"
      end

      identifiers = resources.map(&:to_s)
      available = catalog.map { |summary| summary.fetch(:identifier) }
      unless identifiers.uniq == identifiers && (identifiers - available).empty? &&
          identifiers.all? { |identifier| authorized.key?(identifier) }
        raise PermanentProviderError, "Resource selector returned an unauthorized resource"
      end

      identifiers.freeze
    end

    def selection_outcome(status, output, catalog: nil, question: nil, binding: nil, semantic_context: nil)
      message = output["message"]
      unless message.is_a?(String) && !message.empty? && message.bytesize <= 1_000
        raise PermanentProviderError, "Resource selector returned invalid output"
      end

      attributes = {status: status, warnings: [message], trace_id: SecureRandom.uuid}
      if status == :clarification_required
        choices = output["choices"]
        available = catalog.map { |summary| summary.fetch(:identifier) }
        unless choices.is_a?(Array) && choices.length.between?(1, 10) &&
            choices.all? { |choice| choice.is_a?(String) && available.include?(choice) }
          raise PermanentProviderError, "Resource selector returned invalid output"
        end
        clarification = {message: message.freeze, choices: choices.map(&:freeze).freeze}.freeze
        attributes[:warnings] = ["#{message} Choices: #{choices.join(", ")}"]
        attributes[:clarification] = clarification
        attributes[:continuation] = ContinuationToken.new.issue(
          "stage" => "selection",
          "question" => question.to_s,
          "choices" => choices,
          "binding" => binding
        )
      end
      BusinessOutcome.new(**attributes, semantic_grounding: semantic_grounding(semantic_context))
    end

    def validate_planning_facts!(facts)
      unless safe_fact?(facts) && JSON.generate(facts).bytesize <= MAX_PLANNING_FACT_BYTES
        raise ConfigurationError, "planning facts must contain only bounded scalar values"
      end
    end

    def authorized_semantic_context(authorized)
      snapshot = Maglev.semantic_snapshot
      return unless snapshot

      AuthorizedSemanticContext.new(snapshot: snapshot, authorized_resources: authorized)
    end

    def interpret_semantics(question, semantic_context, binding)
      return unless semantic_context

      interpretation = SemanticInterpreter.new(semantic_context).call(question)
      @semantic_meaning_ids = interpretation.meaning_ids unless interpretation.status == :none
      case interpretation.status
      when :clarification_required
        @semantic_contest_ids = interpretation.meaning_ids
        clarification = {
          message: interpretation.message.freeze,
          choices: interpretation.choices.map(&:freeze).freeze
        }.freeze
        token = ContinuationToken.new.issue(
          "stage" => "semantic",
          "question" => question.to_s,
          "semantic_name" => interpretation.meaning_ids.filter_map do |id|
            semantic_context.meanings.find { |meaning| meaning.fetch(:id) == id }&.fetch(:name)
          end.first,
          "choices" => interpretation.choices,
          "binding" => binding
        )
        BusinessOutcome.new(status: :clarification_required, trace_id: SecureRandom.uuid,
          clarification: clarification, continuation: token,
          semantic_grounding: semantic_grounding(semantic_context))
      when :unsupported
        BusinessOutcome.new(status: :unsupported, trace_id: SecureRandom.uuid,
          warnings: [interpretation.message],
          semantic_grounding: semantic_grounding(semantic_context))
      else
        interpretation
      end
    end

    def execute_semantic_ir(interpretation, authorized, semantic_context)
      resource = interpretation.ir.fetch("root")
      authorization = authorized.fetch(resource)
      snapshot = Registry.snapshot(resources: [resource],
        authorizer: ->(*) { true },
        limits: {
          resources: Maglev.configuration.selected_resource_max_count,
          bytes: Maglev.configuration.selected_schema_max_bytes
        })
      validation = QueryValidator.new(snapshot: snapshot, root: resource).call(interpretation.ir)
      raise PlanValidationError, "Semantic meaning did not compile to authorized Query IR" unless validation.valid?

      plan = Planner::Plan.new(status: :ready, resource: resource, ir: validation.ir,
        explanation: validation.explanation, validation: validation,
        base_relation: authorization.fetch(:base_relation), trace_id: SecureRandom.uuid)
      outcome_for(Maglev.execute(plan), semantic_context)
    end

    def safe_fact?(value)
      case value
      when Hash
        value.all? { |key, item| (key.is_a?(String) || key.is_a?(Symbol)) && safe_fact?(item) }
      when Array
        value.length <= 100 && value.all? { |item| safe_fact?(item) }
      when String
        value.bytesize <= 1_000
      when Numeric, TrueClass, FalseClass, NilClass
        true
      else
        false
      end
    end

    def deep_freeze(value)
      case value
      when Hash then value.to_h { |key, item| [deep_freeze(key), deep_freeze(item)] }.freeze
      when Array then value.map { |item| deep_freeze(item) }.freeze
      else value.frozen? ? value : value.freeze
      end
    end

    def continuation_binding(user, context, authorized)
      values = authorized.values.map do |resource|
        [resource.fetch(:identifier), resource.fetch(:planning_facts)]
      end
      Digest::SHA256.hexdigest(Marshal.dump([user, context, values]))
    rescue TypeError
      raise ConfigurationError, "user and context must support continuation binding"
    end

    def resume_clarification(answer, state, authorized)
      choices = state["choices"]
      unless %w[selection planning semantic].include?(state["stage"]) && choices.is_a?(Array) &&
          answer.is_a?(String) && answer.bytesize <= 200 && choices.include?(answer)
        raise ArgumentError, "invalid clarification response"
      end

      resources = if state["stage"] == "selection"
        [answer]
      elsif state["stage"] == "semantic"
        nil
      else
        state["resources"]
      end
      valid_resources = resources.nil? ||
        (resources.is_a?(Array) && resources.all? { |identifier| authorized.key?(identifier) })
      unless valid_resources
        raise ArgumentError, "invalid clarification response"
      end

      resumed_question = if state["stage"] == "semantic"
        "#{state.fetch("question")}\nClarification: #{answer}:#{state.fetch("semantic_name")}"
      else
        "#{state.fetch("question")}\nClarification: #{answer}"
      end
      [resumed_question, resources&.freeze]
    end

    def planning_clarification_outcome(plan, question, selection, binding, semantic_context)
      clarification = plan.clarification
      token = ContinuationToken.new.issue(
        "stage" => "planning",
        "question" => question.to_s,
        "choices" => clarification.fetch(:choices),
        "resources" => selection,
        "binding" => binding
      )
      BusinessOutcome.new(status: :clarification_required, trace_id: plan.trace_id,
        clarification: clarification, continuation: token,
        semantic_grounding: semantic_grounding(semantic_context))
    end

    def outcome_for(result, semantic_context)
      status = {
        succeeded: :answered,
        clarification_required: :clarification_required,
        unsupported: :unsupported,
        failed: :failed
      }.fetch(result.status)
      answer = if status == :answered
        (result.route == :knowledge) ? result.value : StructuredAnswerComposer.new.compose(result)
      end
      warnings = result.warnings
      warnings = [SAFE_FAILURE_WARNING] if status == :failed && warnings.empty?
      evidence = result.evidence if status == :answered || result.route == :knowledge
      BusinessOutcome.new(status: status, answer: answer, evidence: evidence,
        warnings: warnings, trace_id: result.trace_id,
        semantic_grounding: grounding_for_status(status, semantic_context))
    end

    def grounding_for_status(status, semantic_context)
      return SemanticGrounding.minimal(semantic_context) if status == :failed

      semantic_grounding(semantic_context)
    end

    def semantic_grounding(semantic_context)
      if semantic_context
        SemanticGrounding.from(semantic_context, meaning_ids: @semantic_meaning_ids,
          contest_ids: @semantic_contest_ids || [])
      end
    end
  end

  def self.ask(question, user:, context:, continuation: nil)
    BusinessQuestionEngine.new.ask(question, user: user, context: context,
      continuation: continuation)
  end
end
