# frozen_string_literal: true

require_relative "errors"
require_relative "semantic_graph"
require_relative "semantic_snapshot"
require_relative "registry"

module Maglev
  # An immutable, request-scoped semantic view bounded by existing Resource authorization.
  class AuthorizedSemanticContext
    ResolutionError = Class.new(Maglev::Error)

    attr_reader :snapshot_fingerprint, :nodes, :edges, :evidence, :claims, :meanings

    def initialize(snapshot:, authorized_resources:)
      @snapshot_fingerprint = snapshot.build_input_fingerprint
      @authorized_resources = authorized_resources.transform_keys(&:to_s).freeze
      graph = snapshot.graph
      entity_bindings = authorized_entity_bindings(graph)
      included_ids = relevant_node_ids(graph, entity_bindings.keys)
      @nodes = graph.nodes.select { |node| included_ids.include?(node.id) }.freeze
      @edges = graph.edges.select do |edge|
        included_ids.include?(edge.source_id) && included_ids.include?(edge.target_id)
      end.freeze
      assertion_ids = included_ids | @edges.map(&:id)
      @claims = graph.claims.select { |claim| assertion_ids.include?(claim.assertion_id) }.freeze
      evidence_ids = @claims.map(&:evidence_id).to_h { |id| [id, true] }
      @evidence = graph.evidence.select { |item| evidence_ids[item.id] }.freeze
      @meanings = @nodes.map do |node|
        {
          id: node.id,
          kind: node.kind,
          context: node.context,
          name: node.name,
          semantic_status: graph.semantic_status_for(node.id),
          execution_status: execution_status(node, entity_bindings)
        }.freeze
      end.freeze
      @provider_payload = deep_freeze(
        snapshot_fingerprint: @snapshot_fingerprint,
        meanings: @meanings,
        relationships: @edges.map { |edge|
          {id: edge.id, kind: edge.kind, source_id: edge.source_id,
           target_id: edge.target_id}
        },
        claims: @claims.map { |claim|
          {id: claim.id, assertion_id: claim.assertion_id,
           evidence_id: claim.evidence_id, basis: claim.basis,
           polarity: claim.polarity}
        },
        evidence: @evidence.map { |item|
          {id: item.id, source_kind: item.source_kind,
           stable_identity: item.stable_identity, extractor: item.extractor}
        }
      )
      freeze
    end

    attr_reader :provider_payload

    def resolve(name, question:, planning_hints: {})
      candidates = meanings.select { |meaning| meaning[:name] == name.to_s }
      return resolution(:missing, []) if candidates.empty?

      explicit = candidates.select { |meaning| explicitly_qualified?(question, meaning) }
      return resolved(explicit.first) if explicit.one?

      hinted = approved_hint(planning_hints)
      by_hint = candidates.select { |meaning| meaning[:context] == hinted }
      return resolved(by_hint.first) if hinted && by_hint.one?

      associated = associated_candidates(candidates, question)
      return resolved(associated.first) if associated.one?
      return resolved(candidates.first, assumption: true) if candidates.one?

      resolution(:clarification_required, candidates)
    end

    private

    def authorized_entity_bindings(graph)
      evidence = graph.evidence.to_h { |item| [item.id, item] }
      graph.claims.each_with_object({}) do |claim, result|
        node = graph.nodes.find { |candidate| candidate.id == claim.assertion_id }
        item = evidence[claim.evidence_id]
        next unless node&.kind == :entity && claim.polarity == :supports
        next unless item&.source_kind == :registry && item.stable_identity.start_with?("resource:")

        identifier = item.stable_identity.delete_prefix("resource:")
        result[node.id] = identifier if @authorized_resources.key?(identifier) && Registry.fetch(identifier)
      end.freeze
    end

    def relevant_node_ids(graph, entity_ids)
      allowed = entity_ids.to_h { |id| [id, true] }
      changed = true
      while changed
        changed = false
        graph.edges.each do |edge|
          source = graph.nodes.find { |node| node.id == edge.source_id }
          target = graph.nodes.find { |node| node.id == edge.target_id }
          next unless source && target
          next if source.kind == :entity && !entity_ids.include?(source.id)
          next if target.kind == :entity && !entity_ids.include?(target.id)
          next unless allowed[source.id] || allowed[target.id]

          [source.id, target.id].each do |id|
            next if allowed[id]

            allowed[id] = true
            changed = true
          end
        end
      end
      graph.nodes.select { |node| node.kind == :semantic_context && allowed.values_at(*entity_ids).any? }
        .each { |node| allowed[node.id] = true if graph.nodes.any? { |item| allowed[item.id] && item.context == node.context } }
      allowed.keys.freeze
    end

    def execution_status(node, entity_bindings)
      return :unavailable if node.kind == :action
      return :available if entity_bindings.key?(node.id)

      resource_ids = connected_resource_ids(node.id, entity_bindings)
      return :unavailable unless resource_ids.one?

      entry = Registry.fetch(resource_ids.first)
      queryable = entry&.queryable
      return :unavailable unless queryable

      identities = claims.select { |claim| claim.assertion_id == node.id }.filter_map do |claim|
        evidence.find { |item| item.id == claim.evidence_id }&.stable_identity
      end
      available = case node.kind
      when :term
        identities.any? do |identity|
          match = identity.match(/\Ascope:#{Regexp.escape(entry.identifier)}\.([a-zA-Z0-9_]+)\z/)
          match && queryable.scopes.any? { |scope| scope.name.to_s == match[1] }
        end
      when :metric
        identities.any? do |identity|
          match = identity.match(
            /\Aaggregate:#{Regexp.escape(entry.identifier)}\.(count_distinct|count|sum|average|minimum|maximum)\.([a-zA-Z0-9_]+)\z/
          )
          next false unless match

          capability = queryable.aggregates.fetch(match[1].to_sym, nil)
          capability == true || Array(capability).map(&:to_s).include?(match[2])
        end
      when :dimension
        queryable.fields.any? { |field| field.name == node.name }
      else
        false
      end
      available ? :available : :unavailable
    end

    def connected_resource_ids(node_id, entity_bindings)
      edges.filter_map do |edge|
        other = if edge.source_id == node_id
          edge.target_id
        elsif edge.target_id == node_id
          edge.source_id
        end
        entity_bindings[other]
      end.uniq
    end

    def explicitly_qualified?(question, meaning)
      text = question.to_s.downcase
      ["#{meaning[:context]}:#{meaning[:name]}", "#{meaning[:context]}.#{meaning[:name]}",
        "#{meaning[:context]} #{meaning[:name]}"].any? { |qualified| text.include?(qualified.tr("_", " ")) || text.include?(qualified) }
    end

    def approved_hint(hints)
      return unless hints.is_a?(Hash)

      (hints[:semantic_context] || hints["semantic_context"])&.to_s
    end

    def associated_candidates(candidates, question)
      mentioned = meanings.select { |meaning| question.to_s.downcase.include?(meaning[:name].tr("_", " ")) }
        .map { |meaning| meaning[:id] }
      candidates.select do |candidate|
        edges.any? do |edge|
          (edge.source_id == candidate[:id] && mentioned.include?(edge.target_id)) ||
            (edge.target_id == candidate[:id] && mentioned.include?(edge.source_id))
        end
      end
    end

    def resolved(candidate, assumption: false)
      {status: :resolved, id: candidate[:id], context: candidate[:context], assumption: assumption}.freeze
    end

    def resolution(status, candidates)
      {status: status, choices: candidates.map { |candidate| candidate[:context] }.uniq.sort.freeze}.freeze
    end

    def deep_freeze(value)
      case value
      when Hash then value.to_h { |key, item| [deep_freeze(key), deep_freeze(item)] }.freeze
      when Array then value.map { |item| deep_freeze(item) }.freeze
      else value.frozen? ? value : value.freeze
      end
    end
  end
end
