# frozen_string_literal: true

require "rails_helper"

RSpec.describe "authorized structured business questions" do
  around do |example|
    connection = ActiveRecord::Base.connection
    connection.create_table(:business_orders, force: true) do |table|
      table.integer :tenant_id, null: false
      table.string :status, null: false
      table.string :internal_note
    end
    connection.create_table(:business_invoices, force: true) do |table|
      table.integer :tenant_id, null: false
    end
    example.run
  ensure
    connection&.drop_table(:business_invoices, if_exists: true)
    connection&.drop_table(:business_orders, if_exists: true)
  end

  before do
    stub_const("BusinessOrder", Class.new(ActiveRecord::Base) do
      self.table_name = "business_orders"
    end)
    stub_const("BusinessInvoice", Class.new(ActiveRecord::Base) do
      self.table_name = "business_invoices"
    end)
    Maglev::Registry.reset!
    BusinessOrder.maglev_resource :business_orders do
      queryable do
        field :status
        prohibit :internal_note
        aggregates count: true
      end
    end
    BusinessInvoice.maglev_resource :business_invoices
    BusinessOrder.create!(tenant_id: 1, status: "paid", internal_note: "authorized")
    BusinessOrder.create!(tenant_id: 2, status: "paid", internal_note: "secret")
    @original_policy_resolver = Maglev.configuration.policy_resolver
    @original_planner_adapter = Maglev.configuration.planner_adapter
    @original_executor_wrapper = Maglev.configuration.structured_query_executor_wrapper
  end

  after do
    Maglev.configuration.policy_resolver = @original_policy_resolver
    Maglev.configuration.planner_adapter = @original_planner_adapter
    Maglev.configuration.structured_query_executor_wrapper = @original_executor_wrapper
    Maglev::Registry.reset!
  end

  it "answers a scalar question from the policy-authorized relation without leaking opaque inputs" do
    user = "opaque-user-sentinel"
    context = "opaque-context-sentinel"
    resolver_calls = []
    trace_payloads = []
    Maglev.configuration.policy_resolver = lambda do |user:, context:|
      resolver_calls << [user, context]
      {
        business_orders: {
          base_relation: BusinessOrder.where(tenant_id: 1),
          planning_facts: {currency: "AUD"}
        }
      }
    end
    Maglev.configuration.planner_adapter = Maglev::FakePlannerAdapter.new([{
      "status" => "ready",
      "ir" => {
        "version" => 2,
        "root" => "business_orders",
        "operation" => "aggregate",
        "scopes" => [],
        "filters" => [{"field" => "status", "operator" => "eq", "value" => "paid"}],
        "joins" => [],
        "sort" => [],
        "distinct" => false,
        "limit" => 10,
        "aggregate" => {"function" => "count"}
      }
    }])

    callback = ->(_name, _start, _finish, _id, payload) { trace_payloads << payload.dup }
    outcome = ActiveSupport::Notifications.subscribed(callback, /\Amaglev\.structured\./) do
      Maglev.ask("How many paid orders?", user: user, context: context)
    end

    expect(outcome).to be_a(Maglev::BusinessOutcome)
    expect(outcome).to have_attributes(status: :answered, answer: "Count: 1")
    expect(outcome.evidence.scalar).to eq(1)
    expect(outcome).to be_frozen
    expect(resolver_calls).to eq([[user, context]])

    request = Maglev.configuration.planner_adapter.requests.fetch(0)
    expect(request.fetch(:schema_snapshot).to_json).not_to include("internal_note")
    expect(request.fetch(:planning_facts)).to eq(currency: "AUD")
    expect(request.to_s).not_to include(user, context, "authorized", "secret")
    expect(trace_payloads).not_to be_empty
    expect(trace_payloads.to_s).not_to include(user, context)
  end

  it "returns a non-leaking failure instead of executing a query that uses a prohibited field" do
    Maglev.configuration.policy_resolver = lambda do |user:, context:|
      {
        business_orders: {
          base_relation: BusinessOrder.where(tenant_id: user),
          planning_facts: {locale: context}
        }
      }
    end
    invalid_output = {
      "status" => "ready",
      "ir" => {
        "version" => 2,
        "root" => "business_orders",
        "operation" => "records",
        "scopes" => [],
        "filters" => [{"field" => "internal_note", "operator" => "eq", "value" => "secret"}],
        "joins" => [],
        "sort" => [],
        "distinct" => false,
        "limit" => 10
      }
    }
    adapter = Maglev::FakePlannerAdapter.new([invalid_output, invalid_output])
    Maglev.configuration.planner_adapter = adapter
    selected = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      selected << payload[:sql] if payload[:sql]&.start_with?("SELECT")
    end

    outcome = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      Maglev.ask("Show the internal note", user: 1, context: "en-AU")
    end

    expect(outcome).to have_attributes(
      status: :failed,
      answer: nil,
      warnings: ["The question could not be answered safely."]
    )
    expect(outcome.trace_id).not_to be_empty
    expect(selected).to be_empty
    expect(adapter.requests.length).to eq(2)
    expect(adapter.requests.last.fetch(:repair).to_s).not_to include("internal_note", "secret")
  end

  it "fails closed when policy resolution is missing or does not return a matching base relation" do
    Maglev.configuration.policy_resolver = nil
    missing = Maglev.ask("How many orders?", user: Object.new, context: Object.new)

    Maglev.configuration.policy_resolver = ->(user:, context:) {}
    denied = Maglev.ask("How many orders?", user: Object.new, context: Object.new)

    Maglev.configuration.policy_resolver = ->(user:, context:) {}
    nil_resolution = Maglev.ask("How many orders?", user: Object.new, context: Object.new)

    Maglev.configuration.policy_resolver = ->(user:, context:) { raise "resolver failed" }
    resolver_error = Maglev.ask("How many orders?", user: Object.new, context: Object.new)

    Maglev.configuration.policy_resolver = lambda do |user:, context:|
      {unknown_orders: {base_relation: BusinessOrder.all, planning_facts: {}}}
    end
    unknown = Maglev.ask("How many orders?", user: Object.new, context: Object.new)

    Maglev.configuration.policy_resolver = lambda do |user:, context:|
      {
        business_orders: {base_relation: BusinessOrder.all, planning_facts: {}},
        business_invoices: {base_relation: BusinessInvoice.all, planning_facts: {}}
      }
    end
    ambiguous = Maglev.ask("How many records?", user: Object.new, context: Object.new)

    Maglev.configuration.policy_resolver = lambda do |user:, context:|
      {business_orders: {base_relation: user, planning_facts: {context: context.class.name}}}
    end
    invalid = Maglev.ask("How many orders?", user: Object.new, context: Object.new)

    Maglev.configuration.policy_resolver = lambda do |user:, context:|
      {business_orders: {base_relation: BusinessOrder.all, planning_facts: {raw_context: context}}}
    end
    unsafe_facts = Maglev.ask("How many orders?", user: Object.new, context: Object.new)

    expect([missing, denied, nil_resolution, resolver_error, unknown, ambiguous, invalid, unsafe_facts])
      .to all(have_attributes(
        status: :failed,
        answer: nil,
        evidence: nil,
        warnings: ["The question could not be answered safely."]
      ))
  end

  it "preserves the planning trace identity when protected execution fails" do
    Maglev.configuration.policy_resolver = lambda do |user:, context:|
      {business_orders: {base_relation: BusinessOrder.where(tenant_id: user), planning_facts: {locale: context}}}
    end
    Maglev.configuration.planner_adapter = Maglev::FakePlannerAdapter.new([{
      "status" => "ready",
      "ir" => {
        "version" => 2,
        "root" => "business_orders",
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
    Maglev.configuration.structured_query_executor_wrapper = ->(&) { raise "execution failed" }
    planning_trace_ids = []
    callback = lambda do |name, _start, _finish, _id, payload|
      planning_trace_ids << payload.fetch(:trace_id) if name == "maglev.structured.planning"
    end

    outcome = ActiveSupport::Notifications.subscribed(callback, /\Amaglev\.structured\./) do
      Maglev.ask("How many orders?", user: 1, context: "en-AU")
    end

    expect(outcome).to have_attributes(status: :failed, trace_id: planning_trace_ids.fetch(0))
  end
end
