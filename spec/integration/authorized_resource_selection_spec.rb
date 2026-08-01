# frozen_string_literal: true

require "rails_helper"

RSpec.describe "authorized resource selection" do
  around do |example|
    connection = ActiveRecord::Base.connection
    %i[selection_orders selection_invoices selection_secrets].each do |table_name|
      connection.create_table(table_name, force: true) do |table|
        table.integer :tenant_id, null: false
        table.string :private_value
        table.integer :selection_secret_id if table_name == :selection_orders
      end
    end
    example.run
  ensure
    %i[selection_secrets selection_invoices selection_orders].each do |table_name|
      connection&.drop_table(table_name, if_exists: true)
    end
  end

  before do
    stub_const("SelectionOrder", Class.new(ActiveRecord::Base) do
      self.table_name = "selection_orders"
      belongs_to :selection_secret, optional: true
    end)
    stub_const("SelectionInvoice", Class.new(ActiveRecord::Base) { self.table_name = "selection_invoices" })
    stub_const("SelectionSecret", Class.new(ActiveRecord::Base) { self.table_name = "selection_secrets" })
    Maglev::Registry.reset!
    SelectionOrder.maglev_resource :selection_orders do
      description "Customer orders"
      synonyms "purchases"
      queryable { aggregates count: true }
    end
    SelectionInvoice.maglev_resource :selection_invoices do
      description "Issued invoices"
    end
    SelectionSecret.maglev_resource :selection_secrets do
      description "Executive investigations"
    end
    SelectionOrder.create!(tenant_id: 1, private_value: "visible")

    @original = {
      policy_resolver: Maglev.configuration.policy_resolver,
      resource_selector_adapter: Maglev.configuration.resource_selector_adapter,
      planner_adapter: Maglev.configuration.planner_adapter,
      resource_catalog_max_resources: Maglev.configuration.resource_catalog_max_resources,
      resource_catalog_max_bytes: Maglev.configuration.resource_catalog_max_bytes,
      selected_resource_max_count: Maglev.configuration.selected_resource_max_count,
      selected_schema_max_bytes: Maglev.configuration.selected_schema_max_bytes,
      continuation_secret: Maglev.configuration.continuation_secret,
      continuation_store: Maglev.configuration.continuation_store
    }
    Maglev.configuration.policy_resolver = lambda do |user:, context:|
      {
        selection_orders: {base_relation: SelectionOrder.where(tenant_id: user), planning_facts: {locale: context}},
        selection_invoices: {base_relation: SelectionInvoice.where(tenant_id: user), planning_facts: {}}
      }
    end
    Maglev.configuration.planner_adapter = structured_planner
    Maglev.configuration.continuation_secret = "a" * 32
    Maglev.configuration.continuation_store = Maglev::InMemoryContinuationStore.new
  end

  after do
    @original.each { |name, value| Maglev.configuration.public_send(:"#{name}=", value) }
    Maglev::Registry.reset!
  end

  it "selects a relevant authorized resource from summaries before loading its detailed schema" do
    selector = Maglev::FakeResourceSelectorAdapter.new([{
      "status" => "selected",
      "resources" => ["selection_orders"]
    }])
    Maglev.configuration.resource_selector_adapter = selector

    outcome = Maglev.ask("How many purchases?", user: 1, context: "en-AU")

    expect(outcome).to have_attributes(status: :answered, answer: "Count: 1")
    selection_request = selector.requests.fetch(0)
    expect(selection_request.fetch(:catalog)).to eq([
      {
        identifier: "selection_invoices", description: "Issued invoices", synonyms: [],
        structured: true, knowledge: false
      },
      {
        identifier: "selection_orders", description: "Customer orders", synonyms: ["purchases"],
        structured: true, knowledge: false
      }
    ])
    expect(selection_request.to_s).not_to include("private_value", "selection_secrets", "Executive investigations")

    snapshot = Maglev.configuration.planner_adapter.requests.fetch(0).fetch(:schema_snapshot)
    expect(snapshot.resources.map(&:identifier)).to eq(["selection_orders"])
    expect(snapshot.to_json).to include("private_value")
    expect(snapshot.to_json).not_to include("selection_invoices", "selection_secrets")
  end

  it "filters unregistered and unauthorized semantics before every provider payload" do
    graph = semantic_security_graph
    snapshot = Maglev::SemanticSnapshot.new(
      graph: graph, generator_version: Maglev::VERSION,
      build_input_fingerprint: "sha256:test", registry_compatibility_fingerprint: "sha256:test"
    )
    allow(Maglev).to receive(:semantic_snapshot).and_return(snapshot)
    selector = Maglev::FakeResourceSelectorAdapter.new([{
      "status" => "selected", "resources" => ["selection_orders"]
    }])
    Maglev.configuration.resource_selector_adapter = selector

    outcome = Maglev.ask("How many orders?", user: 1, context: "en-AU")

    payloads = [
      selector.requests.fetch(0).fetch(:semantic_context),
      Maglev.configuration.planner_adapter.requests.fetch(0).fetch(:semantic_context),
      outcome
    ].join(" ")
    expect(payloads).to include("entity:sales:selection_order")
    expect(payloads).not_to include("selection_secret", "ghost_account", "compromised")
    expect(outcome.semantic_grounding.to_h).to include(
      snapshot_fingerprint: "sha256:test",
      contexts: ["sales"],
      meanings: [{
        id: "entity:sales:selection_order",
        semantic_status: :observed,
        execution_status: :available
      }]
    )
    expect(outcome.semantic_grounding.to_h.to_s).not_to include(
      "selection_secret", "ghost_account", "compromised"
    )
  end

  it "validates and executes a fixed multi-resource plan before returning bounded evidence" do
    Maglev.configuration.resource_selector_adapter = Maglev::FakeResourceSelectorAdapter.new([{
      "status" => "selected",
      "resources" => %w[selection_orders selection_invoices]
    }])
    Maglev.configuration.planner_adapter = Maglev::FakePlannerAdapter.new([{
      "plan" => {
        "version" => 1,
        "steps" => [
          {
            "id" => "orders", "kind" => "structured", "resource" => "selection_orders",
            "depends_on" => [], "dependency_types" => {},
            "input" => {"ir" => count_ir("selection_orders")}
          },
          {
            "id" => "invoices", "kind" => "structured", "resource" => "selection_invoices",
            "depends_on" => [], "dependency_types" => {},
            "input" => {"ir" => count_ir("selection_invoices")}
          }
        ]
      }
    }])

    outcome = Maglev.ask("Compare orders and invoices", user: 1, context: "en-AU")

    expect(outcome).to be_a(Maglev::BusinessOutcome)
    expect(outcome).to have_attributes(status: :answered, answer: nil)
    expect(outcome.evidence.map { |item| [item.step_id, item.kind, item.value.scalar] }).to eq([
      ["orders", :aggregate, 1],
      ["invoices", :aggregate, 0]
    ])
    request = Maglev.configuration.planner_adapter.requests.fetch(0)
    expect(request.fetch(:schema_snapshot).resources.map(&:identifier)).to eq(
      %w[selection_invoices selection_orders]
    )
    expect(request.fetch(:query_ir_schema)).to eq(Maglev::BusinessQuestionPlanner::PLAN_SCHEMA)
  end

  it "returns unsupported for no match and requests clarification for an ambiguous selection" do
    Maglev.configuration.resource_selector_adapter = Maglev::FakeResourceSelectorAdapter.new([
      {"status" => "unsupported", "message" => "No authorized resource matches this question."},
      {
        "status" => "clarification_required",
        "message" => "Which business record do you mean?",
        "choices" => ["selection_orders", "selection_invoices"]
      }
    ])

    unsupported = Maglev.ask("What is the weather?", user: 1, context: "en-AU")
    ambiguous = Maglev.ask("How many records?", user: 1, context: "en-AU")

    expect(unsupported).to have_attributes(
      status: :unsupported,
      answer: nil,
      warnings: ["No authorized resource matches this question."]
    )
    expect(ambiguous).to have_attributes(
      status: :clarification_required,
      answer: nil,
      warnings: ["Which business record do you mean? Choices: selection_orders, selection_invoices"]
    )
    expect(Maglev.configuration.planner_adapter.requests).to be_empty
  end

  it "fails closed without disclosing unauthorized metadata or accepting an unauthorized selection" do
    Maglev.configuration.policy_resolver = lambda do |user:, context:|
      {
        selection_orders: {base_relation: SelectionOrder.where(tenant_id: user), planning_facts: {}},
        selection_invoices: {base_relation: SelectionInvoice.where(tenant_id: user), planning_facts: {}},
        selection_secrets: nil
      }
    end
    selector = Maglev::FakeResourceSelectorAdapter.new([
      {"status" => "selected", "resources" => ["selection_secrets"]}
    ])
    Maglev.configuration.resource_selector_adapter = selector

    outcome = Maglev.ask("Show investigations", user: 1, context: Object.new)

    expect(outcome).to have_attributes(
      status: :failed,
      warnings: ["The question could not be answered safely."]
    )
    expect(selector.requests.fetch(0).to_s).not_to include(
      "selection_secrets", "Executive investigations", "private_value"
    )
    expect(Maglev.configuration.planner_adapter.requests).to be_empty
  end

  it "validates every plan resource before executing any step" do
    Maglev.configuration.resource_selector_adapter = Maglev::FakeResourceSelectorAdapter.new([{
      "status" => "selected",
      "resources" => %w[selection_orders selection_invoices]
    }])
    planner = Maglev::FakePlannerAdapter.new([{
      "plan" => {
        "version" => 1,
        "steps" => [{
          "id" => "secret", "kind" => "structured", "resource" => "selection_secrets",
          "depends_on" => [], "dependency_types" => {},
          "input" => {"ir" => count_ir("selection_secrets")}
        }]
      }
    }])
    Maglev.configuration.planner_adapter = planner

    outcome = Maglev.ask("Compare records", user: 1, context: "en-AU")

    expect(outcome).to have_attributes(
      status: :failed,
      warnings: ["The question could not be answered safely."]
    )
    expect(planner.requests.length).to eq(1)
  end

  it "enforces configurable deterministic catalog, selection, and selected-schema limits" do
    Maglev.configuration.resource_catalog_max_resources = 1
    Maglev.configuration.resource_catalog_max_bytes = 1_024
    Maglev.configuration.selected_resource_max_count = 1
    Maglev.configuration.selected_schema_max_bytes = 64
    selector = Maglev::FakeResourceSelectorAdapter.new([
      {"status" => "selected", "resources" => ["selection_invoices", "selection_orders"]}
    ])
    Maglev.configuration.resource_selector_adapter = selector

    outcome = Maglev.ask("How many records?", user: 1, context: "en-AU")

    expect(selector.requests).to be_empty
    expect(outcome).to have_attributes(
      status: :failed,
      warnings: ["The question could not be answered safely."]
    )
    expect(Maglev.configuration.planner_adapter.requests).to be_empty
  end

  it "rejects a selected schema that exceeds the configured byte limit" do
    Maglev.configuration.selected_schema_max_bytes = 64
    Maglev.configuration.resource_selector_adapter = Maglev::FakeResourceSelectorAdapter.new([
      {"status" => "selected", "resources" => ["selection_orders"]}
    ])

    outcome = Maglev.ask("How many purchases?", user: 1, context: "en-AU")

    expect(outcome).to have_attributes(
      status: :failed,
      warnings: ["The question could not be answered safely."]
    )
    expect(Maglev.configuration.planner_adapter.requests).to be_empty
  end

  it "fails closed when the configurable catalog byte budget cannot fit a summary" do
    Maglev.configuration.resource_catalog_max_bytes = 1
    selector = Maglev::FakeResourceSelectorAdapter.new([
      {"status" => "selected", "resources" => ["selection_orders"]}
    ])
    Maglev.configuration.resource_selector_adapter = selector

    outcome = Maglev.ask("How many purchases?", user: 1, context: "en-AU")

    expect(outcome).to have_attributes(
      status: :failed,
      warnings: ["The question could not be answered safely."]
    )
    expect(selector.requests).to be_empty
    expect(Maglev.configuration.planner_adapter.requests).to be_empty
  end

  it "fails closed instead of selecting an identifier prefix on partial catalog byte overflow" do
    one_summary_bytes = JSON.generate([{
      identifier: "selection_invoices", description: "Issued invoices", synonyms: [],
      structured: true, knowledge: false
    }]).bytesize
    Maglev.configuration.resource_catalog_max_bytes = one_summary_bytes
    selector = Maglev::FakeResourceSelectorAdapter.new([
      {"status" => "selected", "resources" => ["selection_invoices"]}
    ])
    Maglev.configuration.resource_selector_adapter = selector

    outcome = Maglev.ask("How many purchases?", user: 1, context: "en-AU")

    expect(outcome).to have_attributes(
      status: :failed,
      warnings: ["The question could not be answered safely."]
    )
    expect(selector.requests).to be_empty
    expect(Maglev.configuration.planner_adapter.requests).to be_empty
  end

  def structured_planner
    Maglev::FakePlannerAdapter.new([{
      "status" => "ready",
      "ir" => {
        "version" => 2,
        "root" => "selection_orders",
        "operation" => "aggregate",
        "scopes" => [],
        "filters" => [],
        "joins" => [],
        "sort" => [],
        "distinct" => false,
        "limit" => 10,
        "aggregate" => {"function" => "count"}
      }
    }])
  end

  def count_ir(resource)
    {
      "version" => 2,
      "root" => resource,
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
  end

  def semantic_security_graph
    node = Maglev::SemanticGraph::Node
    evidence = Maglev::SemanticGraph::Evidence
    claim = Maglev::SemanticGraph::Claim
    order = node.new(kind: :entity, context: :sales, name: :selection_order, execution_status: :available)
    secret = node.new(kind: :entity, context: :security, name: :selection_secret, execution_status: :available)
    ghost = node.new(kind: :entity, context: :internal, name: :ghost_account)
    compromised = node.new(kind: :state, context: :security, name: :compromised)
    order_binding = evidence.new(source_kind: :registry, stable_identity: "resource:selection_orders",
      extractor: :registry)
    secret_binding = evidence.new(source_kind: :registry, stable_identity: "resource:selection_secrets",
      extractor: :registry)
    ghost_source = evidence.new(source_kind: :reflection, stable_identity: "ruby:GhostAccount",
      extractor: :reflection)
    state_source = evidence.new(source_kind: :ruby, stable_identity: "ruby:SelectionSecret.compromised",
      extractor: :prism)
    state_edge = Maglev::SemanticGraph::Edge.new(
      kind: :state_of, source_id: compromised.id, target_id: secret.id
    )
    Maglev::SemanticGraph.new(
      nodes: [order, secret, ghost, compromised],
      edges: [state_edge],
      evidence: [order_binding, secret_binding, ghost_source, state_source],
      claims: [
        claim.new(assertion_id: order.id, evidence_id: order_binding.id, basis: :registry, polarity: :supports),
        claim.new(assertion_id: secret.id, evidence_id: secret_binding.id, basis: :registry, polarity: :supports),
        claim.new(assertion_id: ghost.id, evidence_id: ghost_source.id, basis: :reflection, polarity: :supports),
        claim.new(assertion_id: compromised.id, evidence_id: state_source.id, basis: :syntax, polarity: :supports)
      ]
    )
  end
end
