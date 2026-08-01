# frozen_string_literal: true

module Maglev
  # Resolves only question-visible authorized meanings and compiles the small
  # executable subset to the already validated Query IR.
  class SemanticInterpreter
    Result = Data.define(:status, :meaning_ids, :choices, :ir, :message)

    def initialize(context)
      @context = context
    end

    def call(question)
      mentioned = @context.meanings.select { |meaning| mentioned?(question, meaning) }
      return result(:none) if mentioned.empty?

      resolved = []
      mentioned.group_by { |meaning| meaning.fetch(:name) }.each do |name, _candidates|
        resolution = @context.resolve(name, question: question)
        if resolution.fetch(:status) == :clarification_required
          ids = mentioned.select { |meaning| meaning.fetch(:name) == name }.map { |meaning| meaning.fetch(:id) }
          return result(:clarification_required, meaning_ids: ids,
            choices: resolution.fetch(:choices),
            message: "Which semantic context do you mean for #{name.tr("_", " ")}?")
        end
        resolved << @context.meanings.find { |meaning| meaning.fetch(:id) == resolution.fetch(:id) }
      end

      unavailable = resolved.find do |meaning|
        meaning.fetch(:execution_status) == :unavailable || meaning.fetch(:kind) == :action
      end
      if unavailable
        return result(:unsupported, meaning_ids: resolved.map { |meaning| meaning.fetch(:id) },
          message: "The required semantic meaning is not safely executable.")
      end

      missing = resolved.find { |meaning| meaning.fetch(:semantic_status) == :missing }
      if missing
        return result(:unsupported, meaning_ids: resolved.map { |meaning| meaning.fetch(:id) },
          message: "The required semantic meaning is missing.")
      end

      metric = resolved.find { |meaning| meaning.fetch(:kind) == :metric }
      return result(:resolved, meaning_ids: resolved.map { |meaning| meaning.fetch(:id) }) unless metric

      bound_terms = connected_meanings(metric, :term)
      used = (resolved + bound_terms).uniq { |meaning| meaning.fetch(:id) }
      ir = compile_metric(metric, used)
      unless ir
        return result(:unsupported, meaning_ids: resolved.map { |meaning| meaning.fetch(:id) },
          message: "The required semantic meaning cannot be compiled safely.")
      end

      result(:compiled, meaning_ids: used.map { |meaning| meaning.fetch(:id) }, ir: ir)
    end

    private

    def mentioned?(question, meaning)
      return false unless %i[term metric dimension state business_rule action].include?(meaning.fetch(:kind))

      name = meaning.fetch(:name)
      text = question.to_s.downcase
      text.include?(name) || text.include?(name.tr("_", " ")) ||
        text.scan(/[a-z0-9]+/).include?(acronym(name))
    end

    def acronym(name)
      name.split("_").map { |part| part[0] }.join
    end

    def compile_metric(metric, resolved)
      identity = identities_for(metric.fetch(:id)).find { |value| value.start_with?("aggregate:") }
      match = identity&.match(/\Aaggregate:([a-zA-Z0-9_]+)\.(count_distinct|count|sum|average|minimum|maximum)\.([a-zA-Z0-9_]+)\z/)
      return unless match

      resource, function, field = match.captures
      aggregate = {"function" => function}
      aggregate["field"] = field unless function == "count" && field == "records"
      scopes = resolved.select { |meaning| meaning.fetch(:kind) == :term }.filter_map do |term|
        scope = identities_for(term.fetch(:id)).find { |value| value.start_with?("scope:#{resource}.") }
        {"name" => scope.split(".", 2).last, "parameters" => {}} if scope
      end
      {
        "version" => QueryIR::VERSION,
        "root" => resource,
        "operation" => "aggregate",
        "scopes" => scopes,
        "filters" => [],
        "joins" => [],
        "sort" => [],
        "distinct" => false,
        "limit" => 10,
        "aggregate" => aggregate,
        "group_by" => []
      }.freeze
    end

    def identities_for(assertion_id)
      evidence = @context.evidence.to_h { |item| [item.id, item.stable_identity] }
      @context.claims.filter_map do |claim|
        evidence[claim.evidence_id] if claim.assertion_id == assertion_id && claim.polarity == :supports
      end
    end

    def connected_meanings(meaning, kind)
      identifiers = @context.edges.filter_map do |edge|
        if edge.source_id == meaning.fetch(:id)
          edge.target_id
        elsif edge.target_id == meaning.fetch(:id)
          edge.source_id
        end
      end
      @context.meanings.select do |candidate|
        candidate.fetch(:kind) == kind && identifiers.include?(candidate.fetch(:id)) &&
          candidate.fetch(:execution_status) == :available
      end
    end

    def result(status, meaning_ids: [], choices: [], ir: nil, message: nil)
      Result.new(status: status, meaning_ids: meaning_ids.freeze, choices: choices.freeze, ir: ir, message: message)
    end
  end
end
