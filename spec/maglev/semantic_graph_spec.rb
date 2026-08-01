# frozen_string_literal: true

require "spec_helper"
require "maglev/semantic_graph"

RSpec.describe Maglev::SemanticGraph do
  def node(name: "subscription", kind: :entity, execution_status: :unavailable)
    Maglev::SemanticGraph::Node.new(
      kind: kind,
      context: "billing",
      name: name,
      execution_status: execution_status
    )
  end

  describe Maglev::SemanticGraph::Node do
    it "represents every semantic kind with a canonical immutable identity" do
      expected_ids = {
        semantic_context: "semantic_context:billing:billing",
        entity: "entity:billing:subscription",
        term: "term:billing:billable_subscription",
        metric: "metric:billing:monthly_recurring_revenue",
        dimension: "dimension:billing:plan",
        state: "state:billing:cancelled",
        transition: "transition:billing:cancellation",
        business_rule: "business_rule:billing:trial_is_not_billable",
        action: "action:billing:cancel_subscription"
      }

      nodes = expected_ids.map do |kind, expected_id|
        name = expected_id.split(":").last
        node = described_class.new(kind: kind, context: "billing", name: name)

        expect(node.id).to eq(expected_id)
        expect(node).to be_frozen
        node
      end

      expect(nodes.map(&:kind)).to eq(expected_ids.keys)
    end

    it "rejects unsupported kinds, non-canonical names, and executable actions" do
      expect { node(kind: :unknown) }
        .to raise_error(Maglev::SemanticGraph::ValidationError, /unsupported semantic node kind/)
      expect { node(name: "Monthly Revenue") }
        .to raise_error(Maglev::SemanticGraph::ValidationError, /canonical snake_case/)
      expect { node(kind: :action, execution_status: :available) }
        .to raise_error(Maglev::SemanticGraph::ValidationError, /Action.*unavailable/)
    end
  end

  describe "graph validation and status resolution" do
    let(:entity) { node }
    let(:edge) do
      described_class::Edge.new(
        kind: :belongs_to_context,
        source_id: entity.id,
        target_id: context.id
      )
    end
    let(:context) { node(name: "billing", kind: :semantic_context) }
    let(:evidence) do
      described_class::Evidence.new(
        source_kind: :ruby,
        stable_identity: "Subscription.billable",
        file: "app/models/subscription.rb",
        line: 12,
        digest: "sha256:abc123",
        extractor: :prism
      )
    end

    it "uses stable Ruby symbol identity while treating location as metadata" do
      moved = described_class::Evidence.new(
        source_kind: :ruby,
        stable_identity: "Subscription.billable",
        file: "app/models/concerns/billable.rb",
        line: 87,
        digest: "sha256:def456",
        extractor: :prism
      )

      expect(evidence.id).to eq("ruby:Subscription.billable")
      expect(moved.id).to eq(evidence.id)
      expect(evidence).to be_frozen
    end

    it "derives observed, reconstructed, contested, and missing status from claims" do
      observed = described_class::Claim.new(
        assertion_id: edge.id, evidence_id: evidence.id, basis: :reflection, polarity: :supports
      )
      reconstructed = described_class::Claim.new(
        assertion_id: entity.id, evidence_id: evidence.id, basis: :test, polarity: :supports
      )
      contradiction = described_class::Claim.new(
        assertion_id: entity.id, evidence_id: evidence.id, basis: :syntax, polarity: :contradicts
      )

      observed_graph = described_class.new(
        nodes: [entity, context], edges: [edge], evidence: [evidence], claims: [observed]
      )
      reconstructed_graph = described_class.new(
        nodes: [entity], edges: [], evidence: [evidence], claims: [reconstructed]
      )
      contested_graph = described_class.new(
        nodes: [entity], edges: [], evidence: [evidence], claims: [reconstructed, contradiction]
      )
      missing_graph = described_class.new(nodes: [entity], edges: [], evidence: [], claims: [])

      expect(observed_graph.semantic_status_for(edge.id)).to eq(:observed)
      expect(reconstructed_graph.semantic_status_for(entity.id)).to eq(:reconstructed)
      expect(contested_graph.semantic_status_for(entity.id)).to eq(:contested)
      expect(missing_graph.semantic_status_for(entity.id)).to eq(:missing)
    end

    it "rejects invalid references and duplicate identities with actionable errors" do
      bad_edge = described_class::Edge.new(
        kind: :describes, source_id: entity.id, target_id: "entity:billing:missing"
      )

      expect do
        described_class.new(nodes: [entity], edges: [bad_edge], evidence: [], claims: [])
      end.to raise_error(described_class::ValidationError, /edge .*target.*entity:billing:missing/)

      expect do
        described_class.new(nodes: [entity, entity], edges: [], evidence: [], claims: [])
      end.to raise_error(described_class::ValidationError, /duplicate node identity.*#{entity.id}/)
    end

    it "enforces collection and identifier bounds" do
      limits = described_class::Limits.new(nodes: 1, edges: 1, evidence: 1, claims: 1)

      expect do
        described_class.new(
          nodes: [entity, node(name: "invoice")],
          edges: [],
          evidence: [],
          claims: [],
          limits: limits
        )
      end.to raise_error(described_class::ValidationError, /nodes has 2 entries; maximum is 1/)

      expect do
        described_class::Node.new(kind: :entity, context: "a" * 65, name: "record")
      end.to raise_error(described_class::ValidationError, /context exceeds 64 characters/)
    end

    it "freezes graph collections and keeps execution status independent" do
      available_entity = node(execution_status: :available)
      graph = described_class.new(nodes: [available_entity], edges: [], evidence: [], claims: [])

      expect(available_entity.execution_status).to eq(:available)
      expect(graph.semantic_status_for(available_entity.id)).to eq(:missing)
      expect(graph).to be_frozen
      expect { graph.nodes << entity }.to raise_error(FrozenError)
    end
  end
end
