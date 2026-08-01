# frozen_string_literal: true

require "spec_helper"
require "maglev/semantic_snapshot"

RSpec.describe Maglev::SemanticSnapshot do
  def graph
    context = Maglev::SemanticGraph::Node.new(
      kind: :semantic_context,
      context: "billing",
      name: "billing"
    )
    entity = Maglev::SemanticGraph::Node.new(
      kind: :entity,
      context: "billing",
      name: "subscription",
      execution_status: :available
    )
    evidence = Maglev::SemanticGraph::Evidence.new(
      source_kind: :ruby,
      stable_identity: "Subscription.billable",
      extractor: :prism,
      file: "app/models/subscription.rb",
      line: 12,
      digest: "sha256:abc123"
    )
    edge = Maglev::SemanticGraph::Edge.new(
      kind: :belongs_to_context,
      source_id: entity.id,
      target_id: context.id
    )
    claim = Maglev::SemanticGraph::Claim.new(
      assertion_id: entity.id,
      evidence_id: evidence.id,
      basis: :syntax,
      polarity: :supports
    )

    Maglev::SemanticGraph.new(
      nodes: [entity, context],
      edges: [edge],
      evidence: [evidence],
      claims: [claim]
    )
  end

  def snapshot(graph: self.graph)
    described_class.new(
      graph: graph,
      generator_version: "0.4.0",
      build_input_fingerprint: "sha256:build",
      registry_compatibility_fingerprint: "sha256:registry"
    )
  end

  def document_for(value = snapshot)
    YAML.safe_load(value.to_yaml, permitted_classes: [], aliases: false)
  end

  it "round trips metadata and a graph through canonical YAML" do
    original = snapshot

    loaded = described_class.load(original.to_yaml)

    expect(loaded.schema_version).to eq(1)
    expect(loaded.generator_version).to eq("0.4.0")
    expect(loaded.build_input_fingerprint).to eq("sha256:build")
    expect(loaded.registry_compatibility_fingerprint).to eq("sha256:registry")
    expect(loaded.graph.nodes.map(&:id)).to eq(original.graph.nodes.map(&:id).sort)
    expect(loaded.graph.semantic_status_for("entity:billing:subscription")).to eq(:reconstructed)
    expect(loaded.to_yaml).to eq(original.to_yaml)
  end

  it "serializes identical graph inputs to byte-identical canonical YAML" do
    reversed = graph
    reordered = Maglev::SemanticGraph.new(
      nodes: reversed.nodes.reverse,
      edges: reversed.edges.reverse,
      evidence: reversed.evidence.reverse,
      claims: reversed.claims.reverse
    )

    expect(snapshot(graph: reordered).to_yaml).to eq(snapshot.to_yaml)
    expect(document_for.keys).to eq(
      %w[
        schema_version generator_version build_input_fingerprint
        registry_compatibility_fingerprint nodes edges evidence claims
      ]
    )
    expect(document_for["nodes"].map { |node| node["id"] }).to eq(
      document_for["nodes"].map { |node| node["id"] }.sort
    )
  end

  it "rejects unsupported versions, malformed documents, and oversized input" do
    unsupported = document_for
    unsupported["schema_version"] = 2

    expect { described_class.load(YAML.dump(unsupported)) }
      .to raise_error(described_class::ValidationError, /unsupported.*schema version.*2/)
    expect { described_class.load("--- []\n") }
      .to raise_error(described_class::ValidationError, /document must be a mapping/)
    expect { described_class.load(snapshot.to_yaml, max_bytes: 10) }
      .to raise_error(described_class::ValidationError, /artifact has .* bytes; maximum is 10/)
  end

  it "recomputes semantic statuses and rejects cached status tampering" do
    tampered = document_for
    entity = tampered["nodes"].find { |node| node["id"] == "entity:billing:subscription" }
    entity["semantic_status"] = "observed"

    expect { described_class.load(YAML.dump(tampered)) }
      .to raise_error(described_class::ValidationError, /cached semantic status.*derived "reconstructed"/)
  end

  it "rejects identifier tampering, collisions, bounds, and reference failures" do
    identifier = document_for
    identifier["nodes"].first["id"] = "entity:billing:tampered"
    expect { described_class.load(YAML.dump(identifier)) }
      .to raise_error(described_class::ValidationError, /identifier does not match/)

    duplicate = document_for
    duplicate["nodes"] << duplicate["nodes"].first.dup
    expect { described_class.load(YAML.dump(duplicate)) }
      .to raise_error(described_class::ValidationError, /duplicate node identity/)

    bounded = Maglev::SemanticGraph::Limits.new(nodes: 1)
    expect { described_class.load(snapshot.to_yaml, limits: bounded) }
      .to raise_error(described_class::ValidationError, /nodes has 2 entries; maximum is 1/)

    reference = document_for
    reference["edges"].first["target_id"] = "entity:billing:missing"
    reference["edges"].first["id"] = Maglev::SemanticGraph::Edge.new(
      kind: reference["edges"].first["kind"],
      source_id: reference["edges"].first["source_id"],
      target_id: reference["edges"].first["target_id"]
    ).id
    expect { described_class.load(YAML.dump(reference)) }
      .to raise_error(described_class::ValidationError, /target references unknown node/)
  end

  it "uses safe YAML parsing without object construction or aliases" do
    expect { described_class.load("--- !ruby/object:Object {}\n") }
      .to raise_error(described_class::ValidationError, /invalid semantic snapshot YAML/)
    expect { described_class.load("--- &snapshot\nschema_version: 1\ncopy: *snapshot\n") }
      .to raise_error(described_class::ValidationError, /invalid semantic snapshot YAML/)
  end

  it "deeply freezes loaded snapshots and their graph values" do
    loaded = described_class.load(snapshot.to_yaml)
    node = loaded.graph.nodes.first
    evidence = loaded.graph.evidence.first

    expect(loaded).to be_frozen
    expect(loaded.graph).to be_frozen
    expect(loaded.graph.nodes).to be_frozen
    expect(node).to be_frozen
    expect(node.id).to be_frozen
    expect(evidence.file).to be_frozen
    expect { loaded.graph.nodes << node }.to raise_error(FrozenError)
  end
end
