# frozen_string_literal: true

require "rails_helper"

RSpec.describe "bounded stateless clarification" do
  around do |example|
    connection = ActiveRecord::Base.connection
    %i[clarification_orders clarification_invoices].each do |table_name|
      connection.create_table(table_name, force: true) do |table|
        table.integer :tenant_id, null: false
      end
    end
    example.run
  ensure
    %i[clarification_invoices clarification_orders].each do |table_name|
      connection&.drop_table(table_name, if_exists: true)
    end
  end

  before do
    stub_const("ClarificationOrder", Class.new(ActiveRecord::Base) do
      self.table_name = "clarification_orders"
    end)
    stub_const("ClarificationInvoice", Class.new(ActiveRecord::Base) do
      self.table_name = "clarification_invoices"
    end)
    Maglev::Registry.reset!
    ClarificationOrder.maglev_resource :clarification_orders
    ClarificationInvoice.maglev_resource :clarification_invoices
    ClarificationOrder.create!(tenant_id: 1)

    @original = {
      policy_resolver: Maglev.configuration.policy_resolver,
      resource_selector_adapter: Maglev.configuration.resource_selector_adapter,
      planner_adapter: Maglev.configuration.planner_adapter,
      continuation_secret: Maglev.configuration.continuation_secret,
      continuation_store: Maglev.configuration.continuation_store,
      continuation_clock: Maglev.configuration.continuation_clock,
      continuation_ttl: Maglev.configuration.continuation_ttl,
      continuation_max_bytes: Maglev.configuration.continuation_max_bytes
    }
    Maglev.configuration.policy_resolver = lambda do |user:, context:|
      {
        clarification_orders: {
          base_relation: ClarificationOrder.where(tenant_id: user),
          planning_facts: {locale: context}
        },
        clarification_invoices: {
          base_relation: ClarificationInvoice.where(tenant_id: user),
          planning_facts: {locale: context}
        }
      }
    end
    Maglev.configuration.continuation_secret = "a" * 32
    Maglev.configuration.continuation_store = Maglev::InMemoryContinuationStore.new
  end

  after do
    @original&.each { |name, value| Maglev.configuration.public_send(:"#{name}=", value) }
    Maglev::Registry.reset!
  end

  it "returns the minimum clarification request with an opaque signed continuation" do
    Maglev.configuration.resource_selector_adapter = Maglev::FakeResourceSelectorAdapter.new([{
      "status" => "clarification_required",
      "message" => "Which business record do you mean?",
      "choices" => %w[clarification_orders clarification_invoices]
    }])

    outcome = Maglev.ask("How many records?", user: 1, context: "en-AU")

    expect(outcome).to be_a(Maglev::BusinessOutcome)
    expect(outcome).to have_attributes(
      status: :clarification_required,
      clarification: {
        message: "Which business record do you mean?",
        choices: %w[clarification_orders clarification_invoices]
      }
    )
    expect(outcome.continuation).to be_a(String)
    expect(outcome.continuation.bytesize).to be_between(40, 4_096)
    expect(outcome.continuation).not_to include(
      "How many records?", "clarification_orders", "en-AU"
    )
  end

  it "reauthorizes and replans exactly once from a valid caller-carried continuation" do
    selector = clarification_selector
    Maglev.configuration.resource_selector_adapter = selector
    planner = successful_planner
    Maglev.configuration.planner_adapter = planner

    clarification = Maglev.ask("How many records?", user: 1, context: "en-AU")
    outcome = Maglev.ask("clarification_orders", user: 1, context: "en-AU",
      continuation: clarification.continuation)

    expect(outcome).to have_attributes(status: :answered, answer: "Count: 1")
    expect(selector.requests.length).to eq(1)
    expect(planner.requests.length).to eq(1)
    expect(planner.requests.fetch(0).fetch(:question)).to eq(
      "How many records?\nClarification: clarification_orders"
    )
  end

  it "rejects a tampered continuation without planning" do
    clarification = issue_clarification
    token = clarification.continuation.dup
    token[-1] = (token[-1] == "a") ? "b" : "a"
    planner = successful_planner
    Maglev.configuration.planner_adapter = planner

    outcome = Maglev.ask("clarification_orders", user: 1, context: "en-AU",
      continuation: token)

    expect(outcome).to have_attributes(
      status: :failed,
      warnings: ["The question could not be answered safely."]
    )
    expect(planner.requests).to be_empty
  end

  it "rejects an expired continuation without planning" do
    now = Time.utc(2026, 7, 27, 12)
    Maglev.configuration.continuation_clock = -> { now }
    Maglev.configuration.continuation_ttl = 60
    clarification = issue_clarification
    now += 61
    planner = successful_planner
    Maglev.configuration.planner_adapter = planner

    outcome = Maglev.ask("clarification_orders", user: 1, context: "en-AU",
      continuation: clarification.continuation)

    expect(outcome.status).to eq(:failed)
    expect(planner.requests).to be_empty
  end

  it "rejects a context-mismatched continuation without planning" do
    clarification = issue_clarification
    planner = successful_planner
    Maglev.configuration.planner_adapter = planner

    outcome = Maglev.ask("clarification_orders", user: 1, context: "fr-FR",
      continuation: clarification.continuation)

    expect(outcome.status).to eq(:failed)
    expect(planner.requests).to be_empty
  end

  it "rejects replay after a successful continuation" do
    clarification = issue_clarification
    planner = Maglev::FakePlannerAdapter.new([
      successful_plan_output,
      successful_plan_output
    ])
    Maglev.configuration.planner_adapter = planner

    first = Maglev.ask("clarification_orders", user: 1, context: "en-AU",
      continuation: clarification.continuation)
    replay = Maglev.ask("clarification_orders", user: 1, context: "en-AU",
      continuation: clarification.continuation)

    expect(first.status).to eq(:answered)
    expect(replay.status).to eq(:failed)
    expect(planner.requests.length).to eq(1)
  end

  it "rejects an answer outside the bounded choices without planning" do
    clarification = issue_clarification
    planner = successful_planner
    Maglev.configuration.planner_adapter = planner

    outcome = Maglev.ask("clarification_secrets", user: 1, context: "en-AU",
      continuation: clarification.continuation)

    expect(outcome.status).to eq(:failed)
    expect(planner.requests).to be_empty

    valid = Maglev.ask("clarification_orders", user: 1, context: "en-AU",
      continuation: clarification.continuation)
    expect(valid.status).to eq(:answered)
  end

  it "resumes a planner clarification by completely replanning the authorized resource" do
    selector = Maglev::FakeResourceSelectorAdapter.new([{
      "status" => "selected",
      "resources" => ["clarification_orders"]
    }])
    Maglev.configuration.resource_selector_adapter = selector
    planner = Maglev::FakePlannerAdapter.new([
      {
        "status" => "clarification_required",
        "message" => "Which order period?",
        "choices" => ["this_month", "last_month"]
      },
      successful_plan_output
    ])
    Maglev.configuration.planner_adapter = planner

    clarification = Maglev.ask("How many orders?", user: 1, context: "en-AU")
    outcome = Maglev.ask("this_month", user: 1, context: "en-AU",
      continuation: clarification.continuation)

    expect(clarification).to have_attributes(
      status: :clarification_required,
      clarification: {
        message: "Which order period?",
        choices: ["this_month", "last_month"]
      }
    )
    expect(outcome.status).to eq(:answered)
    expect(selector.requests.length).to eq(1)
    expect(planner.requests.length).to eq(2)
  end

  it "does not issue another continuation when one clarification cannot resolve ambiguity" do
    Maglev.configuration.resource_selector_adapter = Maglev::FakeResourceSelectorAdapter.new([{
      "status" => "selected",
      "resources" => ["clarification_orders"]
    }])
    Maglev.configuration.planner_adapter = Maglev::FakePlannerAdapter.new([
      {
        "status" => "clarification_required",
        "message" => "Which order period?",
        "choices" => ["this_month", "last_month"]
      },
      {
        "status" => "clarification_required",
        "message" => "Which exact dates?",
        "choices" => ["dates_a", "dates_b"]
      }
    ])

    clarification = Maglev.ask("How many orders?", user: 1, context: "en-AU")
    outcome = Maglev.ask("this_month", user: 1, context: "en-AU",
      continuation: clarification.continuation)

    expect(outcome).to have_attributes(
      status: :unsupported,
      continuation: nil,
      clarification: nil,
      warnings: ["The clarification did not resolve the ambiguity."]
    )
  end

  def issue_clarification
    Maglev.configuration.resource_selector_adapter = clarification_selector
    Maglev.ask("How many records?", user: 1, context: "en-AU")
  end

  def clarification_selector
    Maglev::FakeResourceSelectorAdapter.new([{
      "status" => "clarification_required",
      "message" => "Which business record do you mean?",
      "choices" => %w[clarification_orders clarification_invoices]
    }])
  end

  def successful_planner
    Maglev::FakePlannerAdapter.new([successful_plan_output])
  end

  def successful_plan_output
    {
      "status" => "ready",
      "ir" => {
        "version" => 2,
        "root" => "clarification_orders",
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
end
