# frozen_string_literal: true

require_relative "errors"
require "digest"

module Maglev
  class SemanticGraph
    MAX_IDENTIFIER_CHARACTERS = 200
    MAX_COMPONENT_CHARACTERS = 64
    MAX_METADATA_CHARACTERS = 1_024

    class ValidationError < Maglev::Error
    end

    class Limits
      attr_reader :nodes, :edges, :evidence, :claims

      def initialize(nodes: 10_000, edges: 25_000, evidence: 50_000, claims: 100_000)
        values = {nodes: nodes, edges: edges, evidence: evidence, claims: claims}
        invalid = values.find { |_name, value| !value.is_a?(Integer) || value.negative? }
        raise ArgumentError, "#{invalid.first} limit must be a non-negative Integer" if invalid

        @nodes = nodes
        @edges = edges
        @evidence = evidence
        @claims = claims
        freeze
      end
    end

    module ValidatedValue
      private

      def bounded_string(label, value, maximum: MAX_METADATA_CHARACTERS)
        result = value.to_s.dup.freeze
        raise ValidationError, "#{label} cannot be empty" if result.empty?
        raise ValidationError, "#{label} exceeds #{maximum} characters" if result.length > maximum

        result
      end

      def canonical_component(label, value)
        result = bounded_string(label, value, maximum: MAX_COMPONENT_CHARACTERS)
        return result if Node::IDENTIFIER_COMPONENT.match?(result)

        raise ValidationError,
          "#{label} must be a non-empty canonical snake_case identifier (got #{result.inspect})"
      end

      def validate_identifier!(identifier)
        return if identifier.length <= MAX_IDENTIFIER_CHARACTERS

        raise ValidationError, "identifier exceeds #{MAX_IDENTIFIER_CHARACTERS} characters: #{identifier.inspect}"
      end
    end

    class Node
      include ValidatedValue

      KINDS = %i[
        semantic_context
        entity
        term
        metric
        dimension
        state
        transition
        business_rule
        action
      ].freeze

      IDENTIFIER_COMPONENT = /\A[a-z][a-z0-9]*(?:_[a-z0-9]+)*\z/

      EXECUTION_STATUSES = %i[available unavailable].freeze

      attr_reader :id, :kind, :context, :name, :execution_status

      def initialize(kind:, context:, name:, execution_status: :unavailable)
        @kind = kind.to_s.to_sym
        raise ValidationError, "unsupported semantic node kind: #{kind.inspect}" unless KINDS.include?(@kind)

        @context = canonical_component(:context, context)
        @name = canonical_component(:name, name)
        @execution_status = execution_status.to_s.to_sym
        unless EXECUTION_STATUSES.include?(@execution_status)
          raise ValidationError, "unsupported execution status: #{execution_status.inspect}"
        end
        if @kind == :action && @execution_status != :unavailable
          raise ValidationError, "Action nodes must have unavailable execution status"
        end

        @id = "#{@kind}:#{@context}:#{@name}".freeze
        validate_identifier!(@id)
        freeze
      end
    end

    class Edge
      include ValidatedValue

      attr_reader :id, :kind, :source_id, :target_id

      def initialize(kind:, source_id:, target_id:)
        @kind = canonical_component(:kind, kind)
        @source_id = bounded_string(:source_id, source_id, maximum: MAX_IDENTIFIER_CHARACTERS)
        @target_id = bounded_string(:target_id, target_id, maximum: MAX_IDENTIFIER_CHARACTERS)
        digest = Digest::SHA256.hexdigest([@kind, @source_id, @target_id].join("\0"))[0, 32]
        @id = "edge:#{@kind}:#{digest}".freeze
        freeze
      end
    end

    class Evidence
      include ValidatedValue

      SOURCE_KINDS = %i[ruby registry reflection schema test documentation].freeze

      attr_reader :id, :source_kind, :stable_identity, :file, :line, :digest, :extractor

      def initialize(source_kind:, stable_identity:, extractor:, file: nil, line: nil, digest: nil)
        @source_kind = source_kind.to_s.to_sym
        unless SOURCE_KINDS.include?(@source_kind)
          raise ValidationError, "unsupported evidence source kind: #{source_kind.inspect}"
        end

        @stable_identity = bounded_string(:stable_identity, stable_identity, maximum: 160)
        if @stable_identity.match?(/\s/)
          raise ValidationError, "stable_identity must not contain whitespace"
        end
        @extractor = canonical_component(:extractor, extractor)
        @file = file.nil? ? nil : bounded_string(:file, file)
        if !line.nil? && (!line.is_a?(Integer) || !line.positive?)
          raise ValidationError, "line must be a positive Integer"
        end
        @line = line
        @digest = digest.nil? ? nil : bounded_string(:digest, digest, maximum: 160)
        @id = "#{@source_kind}:#{@stable_identity}".freeze
        validate_identifier!(@id)
        freeze
      end
    end

    class Claim
      include ValidatedValue

      BASES = %i[reflection registry syntax schema test structured_documentation documentation].freeze
      POLARITIES = %i[supports contradicts].freeze

      attr_reader :id, :assertion_id, :evidence_id, :basis, :polarity

      def initialize(assertion_id:, evidence_id:, basis:, polarity:)
        @assertion_id = bounded_string(:assertion_id, assertion_id, maximum: MAX_IDENTIFIER_CHARACTERS)
        @evidence_id = bounded_string(:evidence_id, evidence_id, maximum: MAX_IDENTIFIER_CHARACTERS)
        @basis = basis.to_s.to_sym
        @polarity = polarity.to_s.to_sym
        raise ValidationError, "unsupported claim basis: #{basis.inspect}" unless BASES.include?(@basis)
        raise ValidationError, "unsupported claim polarity: #{polarity.inspect}" unless POLARITIES.include?(@polarity)

        digest = Digest::SHA256.hexdigest([@assertion_id, @evidence_id, @basis, @polarity].join("\0"))[0, 32]
        @id = "claim:#{digest}".freeze
        freeze
      end
    end

    DIRECT_BASES = %i[reflection registry schema].freeze

    attr_reader :nodes, :edges, :evidence, :claims

    def initialize(nodes:, edges:, evidence:, claims:, limits: Limits.new)
      @nodes = nodes.dup.freeze
      @edges = edges.dup.freeze
      @evidence = evidence.dup.freeze
      @claims = claims.dup.freeze

      validate_collection!(:nodes, @nodes, Node, limits.nodes)
      validate_collection!(:edges, @edges, Edge, limits.edges)
      validate_collection!(:evidence, @evidence, Evidence, limits.evidence)
      validate_collection!(:claims, @claims, Claim, limits.claims)
      validate_references!
      freeze
    end

    def semantic_status_for(assertion_id)
      applicable = claims.select { |claim| claim.assertion_id == assertion_id }
      supporting = applicable.select { |claim| claim.polarity == :supports }
      contradicting = applicable.select { |claim| claim.polarity == :contradicts }

      return :missing if supporting.empty?
      return :contested if contradicting.any?
      return :observed if supporting.all? { |claim| DIRECT_BASES.include?(claim.basis) }

      :reconstructed
    end

    private

    def validate_collection!(name, collection, expected_class, maximum)
      if collection.length > maximum
        raise ValidationError, "#{name} has #{collection.length} entries; maximum is #{maximum}"
      end

      wrong = collection.find { |value| !value.is_a?(expected_class) }
      raise ValidationError, "#{name} must contain only #{expected_class} values" if wrong

      duplicate = collection.group_by(&:id).find { |_id, values| values.length > 1 }
      raise ValidationError, "duplicate #{name.to_s.sub(/s\z/, "")} identity: #{duplicate.first}" if duplicate
    end

    def validate_references!
      node_ids = nodes.map(&:id).to_h { |id| [id, true] }
      edges.each do |edge|
        raise ValidationError, "edge #{edge.id} source references unknown node #{edge.source_id}" unless node_ids[edge.source_id]
        raise ValidationError, "edge #{edge.id} target references unknown node #{edge.target_id}" unless node_ids[edge.target_id]
      end

      assertion_ids = node_ids.merge(edges.map(&:id).to_h { |id| [id, true] })
      evidence_ids = evidence.map(&:id).to_h { |id| [id, true] }
      claims.each do |claim|
        unless assertion_ids[claim.assertion_id]
          raise ValidationError, "claim #{claim.id} references unknown assertion #{claim.assertion_id}"
        end
        unless evidence_ids[claim.evidence_id]
          raise ValidationError, "claim #{claim.id} references unknown evidence #{claim.evidence_id}"
        end
      end

      all = nodes + edges + evidence + claims
      collision = all.group_by(&:id).find { |_id, values| values.length > 1 }
      raise ValidationError, "identifier collision across graph objects: #{collision.first}" if collision
    end
  end
end
