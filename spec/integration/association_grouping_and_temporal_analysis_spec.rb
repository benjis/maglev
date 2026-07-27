# frozen_string_literal: true

require "rails_helper"

RSpec.describe "association grouping and temporal analysis" do
  around do |example|
    connection = ActiveRecord::Base.connection
    connection.create_table(:analytical_accounts, force: true) do |table|
      table.string :region, null: false
      table.string :private_segment
    end
    connection.create_table(:analytical_orders, force: true) do |table|
      table.integer :tenant_id, null: false
      table.references :analytical_account, null: false
      table.decimal :total, null: false
      table.datetime :placed_at, null: false
    end
    example.run
  ensure
    connection&.drop_table(:analytical_orders, if_exists: true)
    connection&.drop_table(:analytical_accounts, if_exists: true)
  end

  before do
    stub_const("AnalyticalAccount", Class.new(ActiveRecord::Base) do
      self.table_name = "analytical_accounts"
      has_many :analytical_orders
    end)
    stub_const("AnalyticalOrder", Class.new(ActiveRecord::Base) do
      self.table_name = "analytical_orders"
      belongs_to :analytical_account
    end)
    Maglev::Registry.reset!
    AnalyticalAccount.maglev_resource :analytical_accounts do
      queryable do
        field :region
        prohibit :private_segment
        grouping :region
      end
    end
    AnalyticalOrder.maglev_resource :analytical_orders do
      queryable do
        association :analytical_account, resource: :analytical_accounts
        grouping :placed_at
        limits rows: 100, groups: 10, operations: 30, joins: 1
      end
    end

    north = AnalyticalAccount.create!(region: "North", private_segment: "secret-a")
    south = AnalyticalAccount.create!(region: "South", private_segment: "secret-b")
    AnalyticalOrder.create!(tenant_id: 1, analytical_account: north, total: 12,
      placed_at: Time.zone.parse("2026-06-15 10:00:00"))
    AnalyticalOrder.create!(tenant_id: 1, analytical_account: north, total: 10,
      placed_at: Time.zone.parse("2026-07-01 10:00:00"))
    AnalyticalOrder.create!(tenant_id: 1, analytical_account: south, total: 8,
      placed_at: Time.zone.parse("2026-07-20 10:00:00"))
    AnalyticalOrder.create!(tenant_id: 2, analytical_account: south, total: 99,
      placed_at: Time.zone.parse("2026-07-20 10:00:00"))

    @original_policy_resolver = Maglev.configuration.policy_resolver
    @original_planner_adapter = Maglev.configuration.planner_adapter
    @original_resource_selector_adapter = Maglev.configuration.resource_selector_adapter
    Maglev.configuration.policy_resolver = lambda do |user:, context:|
      {
        analytical_accounts: {
          base_relation: AnalyticalAccount.where(id: AnalyticalOrder.where(tenant_id: user).select(:analytical_account_id)),
          planning_facts: {}
        },
        analytical_orders: {
          base_relation: AnalyticalOrder.where(tenant_id: user),
          planning_facts: {locale: context}
        }
      }
    end
    Maglev.configuration.resource_selector_adapter = Maglev::FakeResourceSelectorAdapter.new(
      Array.new(3) { {"status" => "selected", "resources" => ["analytical_orders", "analytical_accounts"]} }
    )
  end

  after do
    Maglev.configuration.policy_resolver = @original_policy_resolver
    Maglev.configuration.planner_adapter = @original_planner_adapter
    Maglev.configuration.resource_selector_adapter = @original_resource_selector_adapter
    Maglev::Registry.reset!
  end

  it "groups through an authorized registered association while preserving the base relation" do
    Maglev.configuration.planner_adapter = planner_for(
      joins: ["analytical_account"],
      group_by: [{"field" => "analytical_account.region", "label" => "region"}]
    )

    outcome = Maglev.ask("How many orders are in each account region?", user: 1, context: "en-AU")

    expect(outcome).to have_attributes(status: :answered)
    expect(outcome.evidence.first.value.records).to eq([
      {"region" => "North", "order_count" => 2},
      {"region" => "South", "order_count" => 1}
    ])
  end

  it "groups temporal fields into fixed month buckets" do
    Maglev.configuration.planner_adapter = planner_for(
      group_by: [{"field" => "placed_at", "label" => "month", "bucket" => "month"}]
    )

    outcome = Maglev.ask("How many orders were placed each month?", user: 1, context: "en-AU")

    expect(outcome).to have_attributes(status: :answered)
    expect(outcome.evidence.first.value.records).to eq([
      {"month" => Time.zone.parse("2026-06-01 00:00:00"), "order_count" => 1},
      {"month" => Time.zone.parse("2026-07-01 00:00:00"), "order_count" => 2}
    ])
  end

  it "fails closed for blocked traversal, missing joins, and unsupported buckets" do
    invalid_groups = [
      {joins: ["analytical_account"],
       group_by: [{"field" => "analytical_account.private_segment", "label" => "segment"}]},
      {joins: [], group_by: [{"field" => "analytical_account.region", "label" => "region"}]},
      {joins: [], group_by: [{"field" => "placed_at", "label" => "period", "bucket" => "fortnight"}]}
    ]

    invalid_groups.each do |options|
      Maglev.configuration.planner_adapter = Maglev::FakePlannerAdapter.new([
        planner_output(**options), planner_output(**options)
      ])

      expect(Maglev.ask("Use a blocked analytical path", user: 1, context: "en-AU"))
        .to have_attributes(status: :failed, evidence: nil)
    end
  end

  def planner_for(**options)
    Maglev::FakePlannerAdapter.new([planner_output(**options)])
  end

  def planner_output(group_by:, joins: [])
    {
      "plan" => {
        "version" => 1,
        "steps" => [{
          "id" => "orders_by_group",
          "kind" => "structured",
          "resource" => "analytical_orders",
          "depends_on" => [],
          "dependency_types" => {},
          "input" => {
            "ir" => {
              "version" => 2, "root" => "analytical_orders", "operation" => "aggregate",
              "scopes" => [], "filters" => [], "joins" => joins, "sort" => [],
              "distinct" => false, "limit" => 100,
              "aggregate" => {"function" => "count", "label" => "order_count"},
              "group_by" => group_by
            }
          }
        }]
      }
    }
  end
end
