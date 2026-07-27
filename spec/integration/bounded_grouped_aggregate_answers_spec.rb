# frozen_string_literal: true

require "rails_helper"

RSpec.describe "bounded grouped aggregate business answers" do
  around do |example|
    connection = ActiveRecord::Base.connection
    connection.create_table(:aggregate_orders, force: true) do |table|
      table.integer :tenant_id, null: false
      table.string :region, null: false
      table.decimal :total, null: false
      table.string :internal_code
    end
    example.run
  ensure
    connection&.drop_table(:aggregate_orders, if_exists: true)
  end

  before do
    stub_const("AggregateOrder", Class.new(ActiveRecord::Base) do
      self.table_name = "aggregate_orders"
    end)
    Maglev::Registry.reset!
    AggregateOrder.maglev_resource :aggregate_orders do
      queryable do
        field :tenant_id
        prohibit :internal_code
        grouping :region
        limits rows: 100, groups: 10, operations: 30
      end
    end
    [
      [1, "North", 12, "private-a"],
      [1, "South", 8, "private-b"],
      [1, "North", 10, "private-c"],
      [2, "West", 99, "other-tenant"]
    ].each do |tenant_id, region, total, internal_code|
      AggregateOrder.create!(tenant_id: tenant_id, region: region, total: total, internal_code: internal_code)
    end
    @original_policy_resolver = Maglev.configuration.policy_resolver
    @original_planner_adapter = Maglev.configuration.planner_adapter
    @original_evidence_bytes = Maglev.configuration.structured_evidence_max_bytes
  end

  after do
    Maglev.configuration.policy_resolver = @original_policy_resolver
    Maglev.configuration.planner_adapter = @original_planner_adapter
    Maglev.configuration.structured_evidence_max_bytes = @original_evidence_bytes
    Maglev::Registry.reset!
  end

  it "returns deterministic labelled table evidence for an authorized grouped count" do
    Maglev.configuration.policy_resolver = lambda do |user:, context:|
      {aggregate_orders: {base_relation: AggregateOrder.where(tenant_id: user), planning_facts: {locale: context}}}
    end
    Maglev.configuration.planner_adapter = Maglev::FakePlannerAdapter.new([{
      "status" => "ready",
      "ir" => {
        "version" => 2,
        "root" => "aggregate_orders",
        "operation" => "aggregate",
        "scopes" => [],
        "filters" => [],
        "joins" => [],
        "sort" => [],
        "distinct" => false,
        "limit" => 100,
        "aggregate" => {"function" => "count", "label" => "order_count"},
        "group_by" => [{"field" => "region", "label" => "region"}]
      }
    }])

    outcome = Maglev.ask("How many orders are in each region?", user: 1, context: "en-AU")

    expect(outcome).to have_attributes(status: :answered)
    expect(outcome.evidence.records).to eq([
      {"region" => "North", "order_count" => 2},
      {"region" => "South", "order_count" => 1}
    ])
    expect(outcome.evidence).to have_attributes(count: 2, truncated: false)
    expect(outcome.answer).to eq("region | order_count\nNorth | 2\nSouth | 1")
  end

  it "infers and returns a scalar sum for a reflected numeric field" do
    Maglev.configuration.policy_resolver = lambda do |user:, context:|
      {aggregate_orders: {base_relation: AggregateOrder.where(tenant_id: user), planning_facts: {locale: context}}}
    end
    Maglev.configuration.planner_adapter = Maglev::FakePlannerAdapter.new([{
      "status" => "ready",
      "ir" => {
        "version" => 2, "root" => "aggregate_orders", "operation" => "aggregate",
        "scopes" => [], "filters" => [], "joins" => [], "sort" => [],
        "distinct" => false, "limit" => 100,
        "aggregate" => {"function" => "sum", "field" => "total", "label" => "revenue"},
        "group_by" => []
      }
    }])

    outcome = Maglev.ask("What is total revenue?", user: 1, context: "en-AU")

    expect(outcome).to have_attributes(status: :answered, answer: "Sum: 30.0")
    expect(outcome.evidence.scalar).to eq(30)
  end

  it "fails closed for incompatible aggregates and fields outside grouping policy" do
    Maglev.configuration.policy_resolver = lambda do |user:, context:|
      {aggregate_orders: {base_relation: AggregateOrder.where(tenant_id: user), planning_facts: {locale: context}}}
    end
    invalid_type = {
      "status" => "ready",
      "ir" => {
        "version" => 2, "root" => "aggregate_orders", "operation" => "aggregate",
        "scopes" => [], "filters" => [], "joins" => [], "sort" => [],
        "distinct" => false, "limit" => 100,
        "aggregate" => {"function" => "sum", "field" => "region", "label" => "bad_sum"},
        "group_by" => []
      }
    }
    blocked_group = {
      "status" => "ready",
      "ir" => invalid_type.fetch("ir").merge(
        "aggregate" => {"function" => "count", "label" => "count"},
        "group_by" => [{"field" => "tenant_id", "label" => "tenant"}]
      )
    }

    [invalid_type, blocked_group].each do |invalid|
      Maglev.configuration.planner_adapter = Maglev::FakePlannerAdapter.new([invalid, invalid])
      outcome = Maglev.ask("Use a prohibited analytical capability", user: 1, context: "en-AU")

      expect(outcome).to have_attributes(status: :failed, evidence: nil)
    end
  end

  it "fails safely when grouped result cardinality exceeds the policy limit" do
    AggregateOrder.maglev_resource :aggregate_orders do
      queryable do
        grouping :region
        limits rows: 100, groups: 1, operations: 30
      end
    end
    Maglev.configuration.policy_resolver = lambda do |user:, context:|
      {aggregate_orders: {base_relation: AggregateOrder.where(tenant_id: user), planning_facts: {locale: context}}}
    end
    output = {
      "status" => "ready",
      "ir" => {
        "version" => 2, "root" => "aggregate_orders", "operation" => "aggregate",
        "scopes" => [], "filters" => [], "joins" => [], "sort" => [],
        "distinct" => false, "limit" => 100,
        "aggregate" => {"function" => "count", "label" => "count"},
        "group_by" => [{"field" => "region", "label" => "region"}]
      }
    }
    Maglev.configuration.planner_adapter = Maglev::FakePlannerAdapter.new([output])

    outcome = Maglev.ask("Count by region", user: 1, context: "en-AU")

    expect(outcome).to have_attributes(
      status: :failed,
      evidence: nil,
      warnings: ["The question could not be answered safely."]
    )
  end

  it "truncates grouped table evidence at the configured result byte budget" do
    Maglev.configuration.structured_evidence_max_bytes = 100
    Maglev.configuration.policy_resolver = lambda do |user:, context:|
      {aggregate_orders: {base_relation: AggregateOrder.where(tenant_id: user), planning_facts: {locale: context}}}
    end
    Maglev.configuration.planner_adapter = Maglev::FakePlannerAdapter.new([{
      "status" => "ready",
      "ir" => {
        "version" => 2, "root" => "aggregate_orders", "operation" => "aggregate",
        "scopes" => [], "filters" => [], "joins" => [], "sort" => [],
        "distinct" => false, "limit" => 100,
        "aggregate" => {"function" => "count", "label" => "count"},
        "group_by" => [{"field" => "region", "label" => "region"}]
      }
    }])

    outcome = Maglev.ask("Count by region", user: 1, context: "en-AU")

    expect(outcome).to have_attributes(status: :answered)
    expect(outcome.evidence).to be_truncated
    expect(outcome.evidence.count).to be < 2
  end
end
