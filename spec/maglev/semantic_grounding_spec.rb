# frozen_string_literal: true

require "spec_helper"
require "maglev"

RSpec.describe Maglev::SemanticGrounding do
  before do
    allow(Maglev::Registry).to receive(:fetch) do |identifier|
      (identifier.to_s == "orders") ? double(identifier: "orders", queryable: nil) : nil
    end
  end

  it "serializes only bounded, immutable references from an authorized semantic context" do
    context = authorized_context

    grounding = described_class.from(context)

    expect(grounding.to_h).to eq(
      snapshot_fingerprint: "sha256:build",
      contexts: ["sales"],
      meanings: [
        {
          id: "entity:sales:order",
          semantic_status: :observed,
          execution_status: :available
        },
        {
          id: "term:sales:paid_order",
          semantic_status: :reconstructed,
          execution_status: :unavailable
        }
      ],
      claim_ids: context.claims.map(&:id),
      evidence_ids: context.evidence.map(&:id),
      assumptions: ["term:sales:paid_order"],
      gaps: [],
      contests: []
    )
    expect(JSON.generate(grounding.to_h).bytesize).to be <= described_class::MAX_SERIALIZED_BYTES
    expect(grounding).to be_frozen
    expect(grounding.to_h).to be_frozen
    expect(grounding.to_h.fetch(:meanings)).to all(be_frozen)
    expect(grounding.to_h.to_s).not_to include("app/models", "opaque-user", "confidence", "reasoning")
  end

  it "is exposed separately from execution Evidence by BusinessOutcome" do
    grounding = described_class.from(authorized_context)

    outcome = Maglev::BusinessOutcome.new(
      status: :answered,
      answer: "One paid order",
      evidence: :execution_evidence,
      semantic_grounding: grounding,
      trace_id: "trace-1"
    )

    expect(outcome).to have_attributes(
      evidence: :execution_evidence,
      semantic_grounding: grounding
    )
    expect(outcome.semantic_grounding).not_to equal(outcome.evidence)
    expect(Maglev::BusinessOutcome.new(status: :unsupported, trace_id: "trace-2").semantic_grounding)
      .to be_nil
  end

  it "can accompany non-failed outcomes while failed outcomes accept only minimal identity" do
    grounding = described_class.from(authorized_context)
    minimal = described_class.minimal(authorized_context)

    %i[clarification_required unsupported partial].each do |status|
      outcome = Maglev::BusinessOutcome.new(
        status: status, semantic_grounding: grounding, trace_id: "trace-1"
      )
      expect(outcome.semantic_grounding).to equal(grounding)
    end
    failed = Maglev::BusinessOutcome.new(
      status: :failed, semantic_grounding: minimal, trace_id: "trace-2"
    )

    expect(failed.semantic_grounding.to_h).to eq(
      snapshot_fingerprint: "sha256:build",
      contexts: [],
      meanings: [],
      claim_ids: [],
      evidence_ids: [],
      assumptions: [],
      gaps: [],
      contests: []
    )
    expect do
      Maglev::BusinessOutcome.new(
        status: :failed, semantic_grounding: grounding, trace_id: "trace-3"
      )
    end.to raise_error(ArgumentError, /failed outcome/)
  end

  it "rejects meaning identifiers outside the Authorized Semantic Context" do
    expect do
      described_class.from(authorized_context, meaning_ids: ["entity:security:secret"])
    end.to raise_error(ArgumentError, /unauthorized meaning/)
  end

  it "enforces collection and total serialized byte bounds" do
    expect { described_class.from(large_context(term_count: 100, with_claims: false)) }
      .to raise_error(ArgumentError, /meanings exceeds item limit/)
    expect { described_class.from(large_context(term_count: 99, with_claims: true)) }
      .to raise_error(ArgumentError, /serialized size limit/)
  end

  def authorized_context
    entity = Maglev::SemanticGraph::Node.new(kind: :entity, context: :sales, name: :order)
    term = Maglev::SemanticGraph::Node.new(kind: :term, context: :sales, name: :paid_order)
    binding = Maglev::SemanticGraph::Evidence.new(
      source_kind: :registry, stable_identity: "resource:orders", extractor: :registry,
      file: "app/models/order.rb", line: 1
    )
    source = Maglev::SemanticGraph::Evidence.new(
      source_kind: :test, stable_identity: "ruby:Order.paid", extractor: :prism,
      file: "spec/models/order_spec.rb", line: 10
    )
    claims = [
      Maglev::SemanticGraph::Claim.new(assertion_id: entity.id, evidence_id: binding.id,
        basis: :registry, polarity: :supports),
      Maglev::SemanticGraph::Claim.new(assertion_id: term.id, evidence_id: source.id,
        basis: :test, polarity: :supports)
    ]
    graph = Maglev::SemanticGraph.new(
      nodes: [entity, term],
      edges: [Maglev::SemanticGraph::Edge.new(kind: :classifies, source_id: term.id, target_id: entity.id)],
      evidence: [binding, source],
      claims: claims
    )
    snapshot = Maglev::SemanticSnapshot.new(
      graph: graph, generator_version: Maglev::VERSION,
      build_input_fingerprint: "sha256:build",
      registry_compatibility_fingerprint: "sha256:registry"
    )
    Maglev::AuthorizedSemanticContext.new(snapshot: snapshot, authorized_resources: {"orders" => {}})
  end

  def large_context(term_count:, with_claims:)
    entity = Maglev::SemanticGraph::Node.new(kind: :entity, context: :sales, name: :order)
    binding = Maglev::SemanticGraph::Evidence.new(
      source_kind: :registry, stable_identity: "resource:orders", extractor: :registry
    )
    terms = term_count.times.map do |index|
      name = "term_#{index}_#{"x" * (55 - index.to_s.length)}"
      Maglev::SemanticGraph::Node.new(kind: :term, context: :sales, name: name)
    end
    evidence = [binding]
    claims = [Maglev::SemanticGraph::Claim.new(
      assertion_id: entity.id, evidence_id: binding.id, basis: :registry, polarity: :supports
    )]
    if with_claims
      terms.each_with_index do |term, index|
        item = Maglev::SemanticGraph::Evidence.new(
          source_kind: :test, stable_identity: "ruby:Order.term_#{index}", extractor: :prism
        )
        evidence << item
        claims << Maglev::SemanticGraph::Claim.new(
          assertion_id: term.id, evidence_id: item.id, basis: :test, polarity: :supports
        )
      end
    end
    graph = Maglev::SemanticGraph.new(
      nodes: [entity, *terms],
      edges: terms.map do |term|
        Maglev::SemanticGraph::Edge.new(kind: :classifies, source_id: term.id, target_id: entity.id)
      end,
      evidence: evidence,
      claims: claims
    )
    snapshot = Maglev::SemanticSnapshot.new(
      graph: graph, generator_version: Maglev::VERSION,
      build_input_fingerprint: "sha256:build",
      registry_compatibility_fingerprint: "sha256:registry"
    )
    Maglev::AuthorizedSemanticContext.new(snapshot: snapshot, authorized_resources: {"orders" => {}})
  end
end
