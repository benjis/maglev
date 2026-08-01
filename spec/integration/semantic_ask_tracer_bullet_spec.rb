# frozen_string_literal: true

require "rails_helper"

RSpec.describe "semantic Maglev.ask tracer bullet" do
  around do |example|
    connection = ActiveRecord::Base.connection
    connection.create_table(:semantic_subscriptions, force: true) do |table|
      table.integer :tenant_id, null: false
      table.decimal :monthly_price, null: false
      table.string :status, null: false
      table.string :plan, null: false
    end
    example.run
  ensure
    connection&.drop_table(:semantic_subscriptions, if_exists: true)
  end

  before do
    stub_const("SemanticSubscription", Class.new(ActiveRecord::Base) do
      self.table_name = "semantic_subscriptions"
      scope :billable, -> { where(status: "active") }
    end)
    Maglev::Registry.reset!
    SemanticSubscription.maglev_resource :semantic_subscriptions do
      queryable do
        field :monthly_price
        field :plan
        scope :billable
        aggregates sum: [:monthly_price], count: true
        grouping :plan
      end
    end
    SemanticSubscription.create!(tenant_id: 1, monthly_price: 20, status: "active", plan: "pro")
    SemanticSubscription.create!(tenant_id: 1, monthly_price: 9, status: "cancelled", plan: "basic")
    SemanticSubscription.create!(tenant_id: 2, monthly_price: 99, status: "active", plan: "pro")

    @original = {
      policy_resolver: Maglev.configuration.policy_resolver,
      planner_adapter: Maglev.configuration.planner_adapter,
      continuation_secret: Maglev.configuration.continuation_secret,
      continuation_store: Maglev.configuration.continuation_store
    }
    Maglev.configuration.continuation_secret = "s" * 32
    Maglev.configuration.continuation_store = Maglev::InMemoryContinuationStore.new
    Maglev.configuration.policy_resolver = lambda do |user:, context:|
      {
        semantic_subscriptions: {
          base_relation: SemanticSubscription.where(tenant_id: user),
          planning_facts: {locale: context}
        }
      }
    end
  end

  after do
    @original&.each { |name, value| Maglev.configuration.public_send(:"#{name}=", value) }
    Maglev::SemanticSnapshotStore.reset!
    Maglev::Registry.reset!
  end

  it "compiles an authorized reconstructed MRR meaning to existing Query IR" do
    activate_snapshot(mrr_graph)
    planner = Maglev::FakePlannerAdapter.new([])
    Maglev.configuration.planner_adapter = planner

    outcome = Maglev.ask("What is MRR?", user: 1, context: "en-AU")

    expect(outcome).to have_attributes(status: :answered, answer: "Sum: 20.0")
    expect(outcome.evidence.scalar).to eq(20)
    expect(outcome.semantic_grounding.meanings.map { |meaning| meaning.fetch(:id) })
      .to contain_exactly(
        "metric:billing:monthly_recurring_revenue",
        "term:billing:billable_subscription"
      )
    expect(outcome.semantic_grounding.assumptions)
      .to contain_exactly(
        "metric:billing:monthly_recurring_revenue",
        "term:billing:billable_subscription"
      )
    expect(planner.requests).to be_empty
  end

  it "clarifies competing authorized meanings and reauthorizes before replanning the answer" do
    activate_snapshot(active_customer_graph)
    calls = 0
    Maglev.configuration.policy_resolver = lambda do |user:, context:|
      calls += 1
      {
        semantic_subscriptions: {
          base_relation: SemanticSubscription.where(tenant_id: user),
          planning_facts: {locale: context}
        }
      }
    end
    planner = Maglev::FakePlannerAdapter.new([count_ir])
    Maglev.configuration.planner_adapter = planner

    clarification = Maglev.ask("How many active customers?", user: 1, context: "en-AU")
    outcome = Maglev.ask("sales", user: 1, context: "en-AU",
      continuation: clarification.continuation)

    expect(clarification).to have_attributes(
      status: :clarification_required,
      clarification: {
        message: "Which semantic context do you mean for active customer?",
        choices: %w[sales support]
      }
    )
    expect(clarification.continuation).not_to include("active_customer", "sales", "support")
    expect(clarification.semantic_grounding.contests).to contain_exactly(
      "term:sales:active_customer", "term:support:active_customer"
    )
    expect(outcome.status).to eq(:answered)
    expect(calls).to eq(2)
    expect(planner.requests.one?).to be(true)
    expect(planner.requests.first.fetch(:question)).to include("sales:active_customer")
  end

  it "removes an unregistered entity before planning, execution, and outcome presentation" do
    graph = mrr_graph_with_unregistered_forecast
    activate_snapshot(graph)
    planner = Maglev::FakePlannerAdapter.new([count_ir])
    Maglev.configuration.planner_adapter = planner

    outcome = Maglev.ask("How many subscriptions?", user: 1, context: "en-AU")

    expect(outcome.status).to eq(:answered)
    expect(planner.requests.first.fetch(:semantic_context).to_s).not_to include("secret_forecast")
    expect(outcome.semantic_grounding.to_h.to_s).not_to include("secret_forecast")
  end

  def activate_snapshot(graph)
    snapshot = Maglev::SemanticSnapshot.new(
      graph: graph,
      generator_version: Maglev::VERSION,
      build_input_fingerprint: "sha256:semantic-tracer",
      registry_compatibility_fingerprint: "sha256:registry"
    )
    allow(Maglev).to receive(:semantic_snapshot).and_return(snapshot)
  end

  def mrr_graph
    entity = node(:entity, :semantic_subscription, :semantic_subscription, :available)
    metric = node(:metric, :billing, :monthly_recurring_revenue, :available)
    term = node(:term, :billing, :billable_subscription, :available)
    binding = evidence(:registry, "resource:semantic_subscriptions", :registry)
    aggregate = evidence(:ruby, "aggregate:semantic_subscriptions.sum.monthly_price", :prism)
    scope = evidence(:ruby, "scope:semantic_subscriptions.billable", :prism)
    Maglev::SemanticGraph.new(
      nodes: [entity, metric, term],
      edges: [
        Maglev::SemanticGraph::Edge.new(kind: :measures, source_id: metric.id, target_id: entity.id),
        Maglev::SemanticGraph::Edge.new(kind: :applies, source_id: metric.id, target_id: term.id),
        Maglev::SemanticGraph::Edge.new(kind: :classifies, source_id: term.id, target_id: entity.id)
      ],
      evidence: [binding, aggregate, scope],
      claims: [
        claim(entity, binding, :registry),
        claim(metric, aggregate, :syntax),
        claim(term, scope, :syntax)
      ]
    )
  end

  def active_customer_graph
    entity = node(:entity, :semantic_subscription, :semantic_subscription, :available)
    sales = node(:term, :sales, :active_customer, :available)
    support = node(:term, :support, :active_customer, :available)
    binding = evidence(:registry, "resource:semantic_subscriptions", :registry)
    sales_scope = evidence(:ruby, "scope:semantic_subscriptions.billable", :prism)
    support_scope = evidence(:test, "ruby:SemanticSubscription.support_active", :prism)
    Maglev::SemanticGraph.new(
      nodes: [entity, sales, support],
      edges: [
        Maglev::SemanticGraph::Edge.new(kind: :classifies, source_id: sales.id, target_id: entity.id),
        Maglev::SemanticGraph::Edge.new(kind: :classifies, source_id: support.id, target_id: entity.id)
      ],
      evidence: [binding, sales_scope, support_scope],
      claims: [
        claim(entity, binding, :registry),
        claim(sales, sales_scope, :syntax),
        claim(support, support_scope, :test)
      ]
    )
  end

  def mrr_graph_with_unregistered_forecast
    base = mrr_graph
    ghost = node(:entity, :internal, :secret_forecast)
    source = evidence(:reflection, "ruby:SecretForecast", :reflection)
    Maglev::SemanticGraph.new(
      nodes: base.nodes + [ghost],
      edges: base.edges,
      evidence: base.evidence + [source],
      claims: base.claims + [claim(ghost, source, :reflection)]
    )
  end

  def count_ir
    {
      "status" => "ready",
      "ir" => {
        "version" => 2,
        "root" => "semantic_subscriptions",
        "operation" => "aggregate",
        "scopes" => [],
        "filters" => [],
        "joins" => [],
        "sort" => [],
        "distinct" => false,
        "limit" => 10,
        "aggregate" => {"function" => "count"},
        "group_by" => []
      }
    }
  end

  def node(kind, context, name, execution_status = :unavailable)
    Maglev::SemanticGraph::Node.new(
      kind: kind, context: context, name: name, execution_status: execution_status
    )
  end

  def evidence(source_kind, stable_identity, extractor)
    Maglev::SemanticGraph::Evidence.new(
      source_kind: source_kind, stable_identity: stable_identity, extractor: extractor
    )
  end

  def claim(assertion, source, basis)
    Maglev::SemanticGraph::Claim.new(
      assertion_id: assertion.id, evidence_id: source.id, basis: basis, polarity: :supports
    )
  end
end
