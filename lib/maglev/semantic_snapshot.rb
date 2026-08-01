# frozen_string_literal: true

require "yaml"
require_relative "semantic_graph"

module Maglev
  class SemanticSnapshot
    SCHEMA_VERSION = 1
    DEFAULT_MAX_BYTES = 10 * 1024 * 1024
    MAX_METADATA_CHARACTERS = 1_024

    class ValidationError < SemanticGraph::ValidationError
    end

    attr_reader :schema_version,
      :generator_version,
      :build_input_fingerprint,
      :registry_compatibility_fingerprint,
      :graph

    def initialize(
      graph:,
      generator_version:,
      build_input_fingerprint:,
      registry_compatibility_fingerprint:
    )
      raise ValidationError, "graph must be a SemanticGraph" unless graph.is_a?(SemanticGraph)

      @schema_version = SCHEMA_VERSION
      @generator_version = metadata(:generator_version, generator_version)
      @build_input_fingerprint = metadata(:build_input_fingerprint, build_input_fingerprint)
      @registry_compatibility_fingerprint =
        metadata(:registry_compatibility_fingerprint, registry_compatibility_fingerprint)
      @graph = graph
      freeze
    end

    def to_yaml
      YAML.dump(canonical_document)
    end

    def self.load(yaml, limits: SemanticGraph::Limits.new, max_bytes: DEFAULT_MAX_BYTES)
      validate_artifact_size!(yaml, max_bytes)
      document = YAML.safe_load(
        yaml,
        permitted_classes: [],
        permitted_symbols: [],
        aliases: false
      )
      Loader.new(document, limits: limits).load
    rescue Psych::Exception => error
      raise ValidationError, "invalid semantic snapshot YAML: #{error.message}"
    end

    def self.validate_artifact_size!(yaml, max_bytes)
      raise ValidationError, "semantic snapshot YAML must be a String" unless yaml.is_a?(String)
      unless max_bytes.is_a?(Integer) && max_bytes >= 0
        raise ArgumentError, "max_bytes must be a non-negative Integer"
      end
      return if yaml.bytesize <= max_bytes

      raise ValidationError,
        "semantic snapshot artifact has #{yaml.bytesize} bytes; maximum is #{max_bytes}"
    end
    private_class_method :validate_artifact_size!

    private

    def metadata(name, value)
      result = value.to_s.dup.freeze
      raise ValidationError, "#{name} cannot be empty" if result.empty?
      if result.length > MAX_METADATA_CHARACTERS
        raise ValidationError, "#{name} exceeds #{MAX_METADATA_CHARACTERS} characters"
      end

      result
    end

    def canonical_document
      {
        "schema_version" => schema_version,
        "generator_version" => generator_version,
        "build_input_fingerprint" => build_input_fingerprint,
        "registry_compatibility_fingerprint" => registry_compatibility_fingerprint,
        "nodes" => graph.nodes.sort_by(&:id).map { |node| serialize_node(node) },
        "edges" => graph.edges.sort_by(&:id).map { |edge| serialize_edge(edge) },
        "evidence" => graph.evidence.sort_by(&:id).map { |item| serialize_evidence(item) },
        "claims" => graph.claims.sort_by(&:id).map { |claim| serialize_claim(claim) }
      }
    end

    def serialize_node(node)
      {
        "id" => node.id,
        "kind" => node.kind.to_s,
        "context" => node.context,
        "name" => node.name,
        "semantic_status" => graph.semantic_status_for(node.id).to_s,
        "execution_status" => node.execution_status.to_s
      }
    end

    def serialize_edge(edge)
      {
        "id" => edge.id,
        "kind" => edge.kind,
        "source_id" => edge.source_id,
        "target_id" => edge.target_id,
        "semantic_status" => graph.semantic_status_for(edge.id).to_s
      }
    end

    def serialize_evidence(item)
      {
        "id" => item.id,
        "source_kind" => item.source_kind.to_s,
        "stable_identity" => item.stable_identity,
        "file" => item.file,
        "line" => item.line,
        "digest" => item.digest,
        "extractor" => item.extractor
      }
    end

    def serialize_claim(claim)
      {
        "id" => claim.id,
        "assertion_id" => claim.assertion_id,
        "evidence_id" => claim.evidence_id,
        "basis" => claim.basis.to_s,
        "polarity" => claim.polarity.to_s
      }
    end

    class Loader
      DOCUMENT_KEYS = %w[
        schema_version generator_version build_input_fingerprint
        registry_compatibility_fingerprint nodes edges evidence claims
      ].freeze
      NODE_KEYS = %w[id kind context name semantic_status execution_status].freeze
      EDGE_KEYS = %w[id kind source_id target_id semantic_status].freeze
      EVIDENCE_KEYS = %w[id source_kind stable_identity file line digest extractor].freeze
      CLAIM_KEYS = %w[id assertion_id evidence_id basis polarity].freeze

      def initialize(document, limits:)
        @document = document
        @limits = limits
      end

      def load
        validate_hash!(@document, "document", DOCUMENT_KEYS)
        unless @document["schema_version"] == SCHEMA_VERSION
          raise ValidationError,
            "unsupported semantic snapshot schema version: #{@document["schema_version"].inspect}"
        end

        nodes = collection("nodes", @limits.nodes).map { |value| load_node(value) }
        edges = collection("edges", @limits.edges).map { |value| load_edge(value) }
        evidence = collection("evidence", @limits.evidence).map { |value| load_evidence(value) }
        claims = collection("claims", @limits.claims).map { |value| load_claim(value) }
        graph = SemanticGraph.new(
          nodes: nodes,
          edges: edges,
          evidence: evidence,
          claims: claims,
          limits: @limits
        )
        validate_statuses!(graph, @document["nodes"] + @document["edges"])

        SemanticSnapshot.new(
          graph: graph,
          generator_version: string!("generator_version", @document["generator_version"]),
          build_input_fingerprint:
            string!("build_input_fingerprint", @document["build_input_fingerprint"]),
          registry_compatibility_fingerprint:
            string!(
              "registry_compatibility_fingerprint",
              @document["registry_compatibility_fingerprint"]
            )
        )
      rescue SemanticGraph::ValidationError => error
        raise error if error.is_a?(ValidationError)

        raise ValidationError, error.message
      end

      private

      def collection(name, maximum)
        value = @document[name]
        raise ValidationError, "#{name} must be an Array" unless value.is_a?(Array)
        if value.length > maximum
          raise ValidationError, "#{name} has #{value.length} entries; maximum is #{maximum}"
        end

        value
      end

      def load_node(value)
        validate_hash!(value, "node", NODE_KEYS)
        object = SemanticGraph::Node.new(
          kind: string!("node kind", value["kind"]),
          context: string!("node context", value["context"]),
          name: string!("node name", value["name"]),
          execution_status: string!("node execution_status", value["execution_status"])
        )
        validate_id!("node", value, object)
        object
      end

      def load_edge(value)
        validate_hash!(value, "edge", EDGE_KEYS)
        object = SemanticGraph::Edge.new(
          kind: string!("edge kind", value["kind"]),
          source_id: string!("edge source_id", value["source_id"]),
          target_id: string!("edge target_id", value["target_id"])
        )
        validate_id!("edge", value, object)
        object
      end

      def load_evidence(value)
        validate_hash!(value, "evidence", EVIDENCE_KEYS)
        object = SemanticGraph::Evidence.new(
          source_kind: string!("evidence source_kind", value["source_kind"]),
          stable_identity: string!("evidence stable_identity", value["stable_identity"]),
          file: optional_string!("evidence file", value["file"]),
          line: value["line"],
          digest: optional_string!("evidence digest", value["digest"]),
          extractor: string!("evidence extractor", value["extractor"])
        )
        validate_id!("evidence", value, object)
        object
      end

      def load_claim(value)
        validate_hash!(value, "claim", CLAIM_KEYS)
        object = SemanticGraph::Claim.new(
          assertion_id: string!("claim assertion_id", value["assertion_id"]),
          evidence_id: string!("claim evidence_id", value["evidence_id"]),
          basis: string!("claim basis", value["basis"]),
          polarity: string!("claim polarity", value["polarity"])
        )
        validate_id!("claim", value, object)
        object
      end

      def validate_hash!(value, label, keys)
        raise ValidationError, "#{label} must be a mapping" unless value.is_a?(Hash)
        return if value.keys == keys

        raise ValidationError,
          "#{label} must contain exactly these canonical keys in order: #{keys.join(", ")}"
      end

      def validate_id!(label, value, object)
        id = string!("#{label} id", value["id"])
        return if id == object.id

        raise ValidationError, "#{label} identifier does not match its canonical fields: #{id}"
      end

      def validate_statuses!(graph, assertions)
        assertions.each do |assertion|
          cached = string!("semantic_status", assertion["semantic_status"])
          derived = graph.semantic_status_for(assertion["id"]).to_s
          next if cached == derived

          raise ValidationError,
            "cached semantic status for #{assertion["id"]} is #{cached.inspect}; derived #{derived.inspect}"
        end
      end

      def string!(label, value)
        raise ValidationError, "#{label} must be a String" unless value.is_a?(String)

        value
      end

      def optional_string!(label, value)
        return nil if value.nil?

        string!(label, value)
      end
    end
  end
end
