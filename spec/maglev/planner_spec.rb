# frozen_string_literal: true

require "spec_helper"
require "maglev"

RSpec.describe Maglev::Planner do
  let(:resource) do
    Maglev::SchemaSnapshot::Resource.new(
      identifier: "orders", description: "Customer orders", synonyms: [], table_name: "orders",
      primary_key: "id", sti_base: nil, inheritance_column: "type",
      fields: [Maglev::SchemaSnapshot::Field.new(name: "status", type: :string, null: false,
        enum_values: %w[paid pending], description: nil, synonyms: [])],
      associations: [], scopes: [], aggregates: {count: true}, limits: {rows: 10},
      allow_unscoped_model_queries: false
    )
  end
  let(:snapshot) { Maglev::SchemaSnapshot.new(resources: [resource], paths: []) }
  let(:valid_ir) do
    {
      "version" => 1, "root" => "orders", "operation" => "records", "scopes" => [],
      "filters" => [{"field" => "status", "operator" => "eq", "value" => "paid"}],
      "joins" => [], "sort" => [], "distinct" => false, "limit" => 5
    }
  end

  it "returns a ready immutable plan from validated provider output without accessing rows" do
    adapter = Maglev::FakePlannerAdapter.new([{"status" => "ready", "ir" => valid_ir}])
    sql = []
    callback = ->(_name, _start, _finish, _id, payload) { sql << payload[:sql] }

    plan = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      described_class.new(adapter: adapter).plan(
        question: "Which orders are paid?", snapshot: snapshot, resource: :orders,
        constraints: {rows: 5}
      )
    end

    expect(plan.status).to eq(:ready)
    expect(plan.route).to eq(:structured)
    expect(plan.ir.to_h).to eq(valid_ir)
    expect(plan.explanation).to include("status eq")
    expect(plan.policy_limits).to eq(rows: 5, operations: 30, joins: 2, complexity: 100)
    expect(plan.evidence_requirements).to eq(kind: :records, max_rows: 5)
    expect(plan).to be_frozen
    expect(sql).to be_empty
    expect(adapter.requests.first).to include(question: "Which orders are paid?", schema_snapshot: snapshot)
    expect(adapter.requests.first.fetch(:query_ir_schema)).to eq(Maglev::Planner::QUERY_IR_SCHEMA)
    expect(adapter.requests.first.fetch(:constraints)).to eq(rows: 5)
  end

  it "makes at most one repair request with safe structured validation errors" do
    invalid = valid_ir.merge("root" => "secret_orders")
    adapter = Maglev::FakePlannerAdapter.new([
      {"status" => "ready", "ir" => invalid},
      {"status" => "ready", "ir" => valid_ir}
    ])

    plan = described_class.new(adapter: adapter).plan(
      question: "Paid orders", snapshot: snapshot, resource: :orders
    )

    expect(plan.status).to eq(:ready)
    expect(adapter.requests.length).to eq(2)
    expect(adapter.requests.last.fetch(:repair)).to match(
      errors: [include(code: :unregistered, path: ["root"])]
    )
    expect(adapter.requests.last.fetch(:repair).to_s).not_to include("secret_orders")
  end

  it "returns invalid when repaired output still fails validation" do
    invalid = valid_ir.merge("root" => "secret_orders")
    adapter = Maglev::FakePlannerAdapter.new(Array.new(2) { {"status" => "ready", "ir" => invalid} })

    plan = described_class.new(adapter: adapter).plan(
      question: "Paid orders", snapshot: snapshot, resource: :orders
    )

    expect(plan.status).to eq(:invalid)
    expect(plan.ir).to be_nil
    expect(plan.errors).to all(be_a(Maglev::QueryValidator::Error))
    expect(adapter.requests.length).to eq(2)
  end

  it "preserves bounded clarification and unsupported outcomes without inventing IR" do
    clarification = described_class.new(adapter: Maglev::FakePlannerAdapter.new([
      {"status" => "clarification_required", "message" => "Which order status?", "choices" => %w[paid pending]}
    ])).plan(question: "Show those orders", snapshot: snapshot, resource: :orders)
    unsupported = described_class.new(adapter: Maglev::FakePlannerAdapter.new([
      {"status" => "unsupported", "message" => "Write requests are unsupported"}
    ])).plan(question: "Delete every order", snapshot: snapshot, resource: :orders)

    expect(clarification.status).to eq(:clarification_required)
    expect(clarification.clarification).to eq(message: "Which order status?", choices: %w[paid pending])
    expect(clarification.ir).to be_nil
    expect(unsupported.status).to eq(:unsupported)
    expect(unsupported.ir).to be_nil
  end
end
