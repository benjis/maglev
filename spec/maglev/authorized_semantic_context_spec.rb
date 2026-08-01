# frozen_string_literal: true

require "spec_helper"
require "maglev/authorized_semantic_context"

RSpec.describe Maglev::AuthorizedSemanticContext do
  before do
    allow(Maglev::Registry).to receive(:fetch) do |identifier|
      (identifier.to_s == "orders" || identifier.to_s == "customers") ? double(identifier: identifier.to_s, queryable: nil) : nil
    end
  end

  def semantic_fixture
    orders = semantic_node(kind: :entity, context: :sales, name: :order, execution_status: :available)
    secrets = semantic_node(kind: :entity, context: :security, name: :secret, execution_status: :available)
    ghosts = semantic_node(kind: :entity, context: :internal, name: :ghost, execution_status: :available)
    total = semantic_node(kind: :metric, context: :sales, name: :total_revenue, execution_status: :available)
    secret_state = semantic_node(kind: :state, context: :security, name: :compromised)
    order_binding = semantic_evidence(source_kind: :registry, stable_identity: "resource:orders", extractor: :registry)
    secret_binding = semantic_evidence(source_kind: :registry, stable_identity: "resource:secrets", extractor: :registry)
    ghost_source = semantic_evidence(source_kind: :reflection, stable_identity: "ruby:Ghost", extractor: :reflection)
    metric_source = semantic_evidence(source_kind: :registry, stable_identity: "aggregate:orders.sum.total", extractor: :registry)
    secret_source = semantic_evidence(source_kind: :ruby, stable_identity: "ruby:Secret.compromised", extractor: :prism)
    measures = semantic_edge(kind: :measures, source_id: total.id, target_id: orders.id)
    exposes = semantic_edge(kind: :state_of, source_id: secret_state.id, target_id: secrets.id)
    claims = [
      semantic_claim(assertion_id: orders.id, evidence_id: order_binding.id, basis: :registry, polarity: :supports),
      semantic_claim(assertion_id: secrets.id, evidence_id: secret_binding.id, basis: :registry, polarity: :supports),
      semantic_claim(assertion_id: ghosts.id, evidence_id: ghost_source.id, basis: :reflection, polarity: :supports),
      semantic_claim(assertion_id: total.id, evidence_id: metric_source.id, basis: :registry, polarity: :supports),
      semantic_claim(assertion_id: secret_state.id, evidence_id: secret_source.id, basis: :syntax, polarity: :supports)
    ]
    graph = Maglev::SemanticGraph.new(
      nodes: [orders, secrets, ghosts, total, secret_state],
      edges: [measures, exposes],
      evidence: [order_binding, secret_binding, ghost_source, metric_source, secret_source],
      claims: claims
    )
    Maglev::SemanticSnapshot.new(
      graph: graph,
      generator_version: Maglev::VERSION,
      build_input_fingerprint: "sha256:build",
      registry_compatibility_fingerprint: "sha256:registry"
    )
  end

  it "removes unregistered and unauthorized graph content at an immutable boundary" do
    context = described_class.new(snapshot: semantic_fixture, authorized_resources: {"orders" => {}})

    expect(context.meanings.map { |meaning| meaning.fetch(:id) })
      .to contain_exactly("entity:sales:order", "metric:sales:total_revenue")
    expect(context.provider_payload.to_s).not_to include("secret", "ghost", "compromised")
    expect(context.evidence.map(&:stable_identity))
      .to contain_exactly("resource:orders", "aggregate:orders.sum.total")
    expect(context).to be_frozen
    expect(context.meanings).to be_frozen
  end

  it "derives execution status from current authorized capabilities, not semantic status" do
    context = described_class.new(snapshot: semantic_fixture, authorized_resources: {"orders" => {}})
    statuses = context.meanings.to_h { |meaning| [meaning.fetch(:id), meaning.fetch(:execution_status)] }

    expect(statuses).to eq(
      "entity:sales:order" => :available,
      "metric:sales:total_revenue" => :unavailable
    )
    expect(context.meanings.find { |meaning| meaning.fetch(:kind) == :metric }.fetch(:semantic_status))
      .to eq(:observed)
  end

  it "resolves explicit qualification, approved hints, one candidate, and ambiguity in order" do
    sales = semantic_node(kind: :term, context: :sales, name: :active_customer)
    support = semantic_node(kind: :term, context: :support, name: :active_customer)
    entity = semantic_node(kind: :entity, context: :sales, name: :customer, execution_status: :available)
    binding = semantic_evidence(source_kind: :registry, stable_identity: "resource:customers", extractor: :registry)
    source = semantic_evidence(source_kind: :test, stable_identity: "ruby:Customer.active", extractor: :prism)
    edges = [
      semantic_edge(kind: :classifies, source_id: sales.id, target_id: entity.id),
      semantic_edge(kind: :classifies, source_id: support.id, target_id: entity.id)
    ]
    claims = [
      semantic_claim(assertion_id: entity.id, evidence_id: binding.id, basis: :registry, polarity: :supports),
      semantic_claim(assertion_id: sales.id, evidence_id: source.id, basis: :test, polarity: :supports),
      semantic_claim(assertion_id: support.id, evidence_id: source.id, basis: :test, polarity: :supports)
    ]
    snapshot = Maglev::SemanticSnapshot.new(
      graph: Maglev::SemanticGraph.new(nodes: [entity, sales, support], edges: edges,
        evidence: [binding, source], claims: claims),
      generator_version: Maglev::VERSION, build_input_fingerprint: "sha256:build",
      registry_compatibility_fingerprint: "sha256:registry"
    )
    context = described_class.new(snapshot: snapshot, authorized_resources: {"customers" => {}})

    expect(context.resolve("active_customer", question: "sales:active_customer").fetch(:context)).to eq("sales")
    expect(context.resolve("active_customer", question: "active customer",
      planning_hints: {semantic_context: "support"}).fetch(:context)).to eq("support")
    expect(context.resolve("active_customer", question: "active customer").fetch(:status)).to eq(:clarification_required)
    expect(context.resolve("customer", question: "customer").fetch(:status)).to eq(:resolved)
  end

  def semantic_node(**attributes) = Maglev::SemanticGraph::Node.new(**attributes)
  def semantic_edge(**attributes) = Maglev::SemanticGraph::Edge.new(**attributes)
  def semantic_evidence(**attributes) = Maglev::SemanticGraph::Evidence.new(**attributes)
  def semantic_claim(**attributes) = Maglev::SemanticGraph::Claim.new(**attributes)
end
