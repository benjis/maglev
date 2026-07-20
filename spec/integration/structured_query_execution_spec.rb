# frozen_string_literal: true

require "rails_helper"

RSpec.describe "structured query compilation and execution" do
  around do |example|
    connection = ActiveRecord::Base.connection
    connection.create_table(:structured_customers, force: true) do |t|
      t.integer :tenant_id, null: false
      t.string :name, null: false
    end
    connection.create_table(:structured_orders, force: true) do |t|
      t.integer :tenant_id, null: false
      t.references :customer, null: false
      t.string :status, null: false
      t.decimal :total, null: false
      t.string :note
      t.datetime :placed_at, null: false
    end
    example.run
  ensure
    connection&.drop_table(:structured_orders, if_exists: true)
    connection&.drop_table(:structured_customers, if_exists: true)
  end

  before do
    stub_const("StructuredCustomer", Class.new(ActiveRecord::Base) do
      self.table_name = "structured_customers"
      has_many :orders, class_name: "StructuredOrder", foreign_key: :customer_id
    end)
    stub_const("StructuredOrder", Class.new(ActiveRecord::Base) do
      self.table_name = "structured_orders"
      belongs_to :customer, class_name: "StructuredCustomer"
      scope :placed_after, ->(value) { where(placed_at: value..) }
      scope :total_between, ->(minimum, maximum) { where(total: minimum..maximum) }
      scope :dangerously_unscoped, -> { unscope(:where) }
      scope :widen_limit, -> { limit(100) }
      scope :locked_rows, -> { lock }
      scope :destructive_scope, -> { delete_all }
    end)

    Maglev::Registry.reset!
    StructuredCustomer.maglev_resource :structured_customers do
      queryable do
        field :name
        authorization :public
      end
    end
    StructuredOrder.maglev_resource :structured_orders do
      queryable do
        field :status, enum: %w[paid pending]
        field :total
        field :placed_at
        field :note
        association :customer, resource: :structured_customers
        scope :placed_after, parameters: {value: {type: :datetime, required: true}}
        scope :total_between, parameters: {
          minimum: {type: :decimal, required: true},
          maximum: {type: :decimal, required: true}
        }
        aggregates count: true, sum: [:total], average: [:total], minimum: [:total], maximum: [:total]
        limits rows: 10, operations: 10, joins: 2
        authorization :public
      end
    end

    @tenant_one_customer = StructuredCustomer.create!(tenant_id: 1, name: "Ada")
    @tenant_two_customer = StructuredCustomer.create!(tenant_id: 2, name: "Ada")
    StructuredOrder.create!(tenant_id: 1, customer: @tenant_one_customer, status: "paid", total: 12, note: nil, placed_at: 2.days.ago)
    StructuredOrder.create!(tenant_id: 1, customer: @tenant_one_customer, status: "pending", total: 8, note: "old", placed_at: 10.days.ago)
    StructuredOrder.create!(tenant_id: 2, customer: @tenant_two_customer, status: "paid", total: 1000, placed_at: 1.day.ago)
  end

  after { Maglev::Registry.reset! }

  it "compiles a validated record plan on the injected tenant relation without executing it" do
    plan = compile(
      "operation" => "records",
      "joins" => ["customer"],
      "filters" => [
        {"field" => "customer.name", "operator" => "eq", "value" => "Ada"},
        {"field" => "status", "operator" => "eq", "value" => "paid"}
      ],
      "sort" => [{"field" => "total", "direction" => "desc"}],
      "distinct" => true,
      "limit" => 5
    )

    expect(plan).to be_records
    expect(plan).not_to be_executed
    expect(plan.relation).to be_a(ActiveRecord::Relation)
    expect(plan.to_sql).to include(%("structured_orders"."tenant_id" = 1))
    expect(plan.to_sql).to include("LIMIT 5")
    expect(plan.operations).to include("join customer", "filter customer.name eq", "sort total desc")
    expect(plan.explanation).to include("Select records from structured_orders")
    expect(plan.warnings).to be_empty
    expect(plan.relation.map(&:total)).to eq([12])
  end

  it "executes registered scopes and every approved predicate without widening the base relation" do
    plan = compile(
      "scopes" => [{"name" => "placed_after", "parameters" => {"value" => 7.days.ago.iso8601}}],
      "filters" => [
        {"field" => "status", "operator" => "in", "value" => %w[paid pending]},
        {"field" => "total", "operator" => "between", "value" => [10, 20]}
      ]
    )

    sql = []
    callback = ->(_name, _start, _finish, _id, payload) { sql << payload[:sql] }
    relation = Maglev::StructuredExecutor.new(timeout: 2.seconds).execute(plan)
    expect(relation).to be_a(ActiveRecord::Relation)
    values = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { relation.map(&:total) }
    expect(values).to eq([12])
    expect(sql).to include("SET LOCAL statement_timeout = 2000", "SET TRANSACTION READ ONLY")
    expect(plan.to_sql).to include(%("structured_orders"."tenant_id" = 1))
  end

  it "passes registered scope parameters in declaration order" do
    plan = compile(
      "scopes" => [{"name" => "total_between", "parameters" => {"minimum" => 10, "maximum" => 20}}]
    )

    expect(plan.relation.map(&:total)).to eq([12])
  end

  it "compiles every approved comparison, set, and null predicate" do
    cases = [
      ["not_eq", "status", "pending", [12]],
      ["gt", "total", 10, [12]],
      ["gte", "total", 12, [12]],
      ["lt", "total", 10, [8]],
      ["lte", "total", 8, [8]],
      ["not_in", "status", ["paid"], [8]],
      ["is_null", "note", nil, [12]],
      ["is_not_null", "note", nil, [8]]
    ]

    cases.each do |operator, field, value, expected|
      predicate = {"field" => field, "operator" => operator}
      predicate["value"] = value unless operator.start_with?("is_")
      plan = compile("filters" => [predicate], "sort" => [{"field" => "total", "direction" => "desc"}])

      expect(plan.relation.map { |record| record.total.to_i }).to eq(expected)
    end
  end

  it "executes each approved aggregate as a bounded scalar over the preserved tenant relation" do
    expected = {count: 2, sum: 20, average: 10, minimum: 8, maximum: 12}

    expected.each do |function, value|
      aggregate = {"function" => function.to_s}
      aggregate["field"] = "total" unless function == :count
      plan = compile("operation" => "aggregate", "aggregate" => aggregate)

      expect(plan).to be_aggregate
      queries = []
      callback = lambda { |_name, _start, _finish, _id, payload| queries << payload[:sql] if payload[:sql].start_with?("SELECT") }
      result = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        Maglev::StructuredExecutor.new.execute(plan)
      end

      expect(result).to eq(value)
      expect(queries.length).to eq(1)
    end
  end

  it "applies PostgreSQL timeout/read-only policy and application-owned execution hooks" do
    seen = []
    wrapper = lambda do |&operation|
      seen << :wrapper
      operation.call
    end
    sql = []
    callback = ->(_name, _start, _finish, _id, payload) { sql << payload[:sql] }

    result = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      Maglev::StructuredExecutor.new(timeout: 0.25, wrapper: wrapper).execute(
        compile("operation" => "aggregate", "aggregate" => {"function" => "count"}, "limit" => 1)
      )
    end

    expect(result).to eq(1)
    expect(seen).to eq([:wrapper])
    expect(sql).to include("SET LOCAL statement_timeout = 250", "SET TRANSACTION READ ONLY")
  end

  it "protects lazy terminal reads and rejects bulk writes on structured relations" do
    sql = []
    callback = ->(_name, _start, _finish, _id, payload) { sql << payload[:sql] }

    count = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      Maglev::StructuredExecutor.new(timeout: 0.1).execute(compile({})).count
    end
    values = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      Maglev::StructuredExecutor.new(timeout: 0.1).execute(compile({})).pluck(:total)
    end

    expect(count).to eq(2)
    expect(values).to contain_exactly(12, 8)
    expect(sql.count("SET LOCAL statement_timeout = 100")).to eq(2)
    expect { Maglev::StructuredExecutor.new.execute(compile({})).delete_all }
      .to raise_error(Maglev::QueryCompilationError, /read-only/)
    expect { compile({}).relation.update_all(status: "paid") }
      .to raise_error(Maglev::QueryCompilationError, /read-only/)
    expect { Maglev::StructuredExecutor.new.execute(compile({})).create!(status: "paid") }
      .to raise_error(Maglev::QueryCompilationError, /read-only/)

    record = Maglev::StructuredExecutor.new.execute(compile("limit" => 1)).first
    expect(record).to be_readonly
    expect { record.update!(status: "pending") }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it "rejects a registered scope that attempts to remove base predicates" do
    StructuredOrder.maglev_resource :structured_orders do
      queryable do
        field :status
        scope :dangerously_unscoped
        limits rows: 10, operations: 10, joins: 2
        authorization :public
      end
    end
    snapshot = Maglev::Registry.snapshot(resources: [:structured_orders])
    validation = validation_for(snapshot, "scopes" => [{"name" => "dangerously_unscoped", "parameters" => {}}])

    expect do
      Maglev::QueryCompiler.new(snapshot: snapshot).compile(
        validation: validation,
        base_relation: StructuredOrder.where(tenant_id: 1)
      )
    end.to raise_error(Maglev::QueryCompilationError, /remove relation constraints/)
  end

  it "rejects registered scopes that replace an injected relation limit" do
    StructuredOrder.maglev_resource :structured_orders do
      queryable do
        field :status
        scope :widen_limit
        limits rows: 10, operations: 10, joins: 2
        authorization :public
      end
    end
    snapshot = Maglev::Registry.snapshot(resources: [:structured_orders])
    validation = validation_for(snapshot, "scopes" => [{"name" => "widen_limit", "parameters" => {}}])

    expect do
      Maglev::QueryCompiler.new(snapshot: snapshot).compile(
        validation: validation,
        base_relation: StructuredOrder.where(tenant_id: 1).limit(1)
      )
    end.to raise_error(Maglev::QueryCompilationError, /widen the base relation/)
  end

  it "rejects registered scopes that introduce locks or other unsafe clauses" do
    StructuredOrder.maglev_resource :structured_orders do
      queryable do
        field :status
        scope :locked_rows
        limits rows: 10, operations: 10, joins: 2
        authorization :public
      end
    end
    snapshot = Maglev::Registry.snapshot(resources: [:structured_orders])
    validation = validation_for(snapshot, "scopes" => [{"name" => "locked_rows", "parameters" => {}}])

    expect do
      Maglev::QueryCompiler.new(snapshot: snapshot).compile(
        validation: validation,
        base_relation: StructuredOrder.where(tenant_id: 1)
      )
    end.to raise_error(Maglev::QueryCompilationError, /widen the base relation/)
  end

  it "prevents writes attempted by application-owned registered scope code" do
    StructuredOrder.maglev_resource :structured_orders do
      queryable do
        field :status
        scope :destructive_scope
        limits rows: 10, operations: 10, joins: 2
        authorization :public
      end
    end
    snapshot = Maglev::Registry.snapshot(resources: [:structured_orders])
    validation = validation_for(snapshot, "scopes" => [{"name" => "destructive_scope", "parameters" => {}}])

    expect do
      Maglev::QueryCompiler.new(snapshot: snapshot).compile(
        validation: validation,
        base_relation: StructuredOrder.where(tenant_id: 1)
      )
    end.to raise_error(Maglev::QueryCompilationError)
    expect(StructuredOrder.count).to eq(3)
  end

  it "keeps a tighter injected relation limit than the validated IR limit" do
    snapshot = Maglev::Registry.snapshot(resources: %i[structured_orders structured_customers])
    validation = validation_for(snapshot, "limit" => 10)
    plan = Maglev::QueryCompiler.new(snapshot: snapshot).compile(
      validation: validation,
      base_relation: StructuredOrder.where(tenant_id: 1).limit(1)
    )

    expect(plan.relation.limit_value).to eq(1)
    expect(plan.relation.length).to eq(1)
  end

  it "rejects invalid validation results, model switching, and incompatible registered scopes before SQL" do
    snapshot = Maglev::Registry.snapshot(resources: %i[structured_orders structured_customers])
    compiler = Maglev::QueryCompiler.new(snapshot: snapshot)
    invalid = Maglev::QueryValidator.new(snapshot: snapshot, root: :structured_orders).call({})
    valid = validation_for(snapshot, "operation" => "records")

    expect { compiler.compile(validation: invalid, base_relation: StructuredOrder.where(tenant_id: 1)) }
      .to raise_error(Maglev::QueryCompilationError, /valid query validation/)
    expect { compiler.compile(validation: valid, base_relation: StructuredCustomer.where(tenant_id: 1)) }
      .to raise_error(Maglev::QueryCompilationError, /does not match/)

    narrower_model = Class.new(StructuredOrder)
    expect { compiler.compile(validation: valid, base_relation: narrower_model.where(tenant_id: 1)) }
      .to raise_error(Maglev::QueryCompilationError, /does not match/)

    other_snapshot = Maglev::Registry.snapshot(resources: [:structured_orders], limits: {fields: 1})
    other_validation = validation_for(other_snapshot, "operation" => "records")
    expect { compiler.compile(validation: other_validation, base_relation: StructuredOrder.where(tenant_id: 1)) }
      .to raise_error(Maglev::QueryCompilationError, /valid query validation/)
  end

  it "rejects hidden fields, SQL fragments, arbitrary scopes, and excess complexity before querying" do
    snapshot = Maglev::Registry.snapshot(resources: %i[structured_orders structured_customers])
    candidates = [
      {"filters" => [{"field" => "tenant_id", "operator" => "eq", "value" => 2}]},
      {"sql" => "SELECT * FROM structured_orders"},
      {"scopes" => [{"name" => "delete_all", "parameters" => {}}]},
      {"joins" => %w[customer customer customer]}
    ]
    selects = []
    callback = ->(_name, _start, _finish, _id, payload) { selects << payload[:sql] if payload[:sql].start_with?("SELECT") }

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      candidates.each do |overrides|
        input = {
          "version" => 1, "root" => "structured_orders", "operation" => "records",
          "scopes" => [], "filters" => [], "joins" => [], "sort" => [], "distinct" => false, "limit" => 10
        }.merge(overrides)
        expect(Maglev::QueryValidator.new(snapshot: snapshot, root: :structured_orders).call(input)).not_to be_valid
      end
    end

    expect(selects).to be_empty
  end

  it "executes a ready public plan into an immutable bounded relation result and structured evidence" do
    adapter = Maglev::FakePlannerAdapter.new([{"status" => "ready", "ir" => {
      "version" => 1, "root" => "structured_orders", "operation" => "records",
      "scopes" => [], "filters" => [{"field" => "status", "operator" => "eq", "value" => "paid"}],
      "joins" => [], "sort" => [], "distinct" => false, "limit" => 1
    }}])
    plan = Maglev.plan("Paid orders", resource: :structured_orders,
      base_relation: StructuredOrder.where(tenant_id: 1), adapter: adapter)

    result = Maglev.execute(plan)

    expect(result).to be_frozen
    expect(result).to have_attributes(status: :succeeded, route: :structured, kind: :relation,
      trace_id: plan.trace_id, warnings: [])
    expect(result.value).to be_a(ActiveRecord::Relation)
    expect(result.value).not_to be_loaded
    expect(result.evidence).to be_frozen
    expect(result.evidence).to have_attributes(count: 1, truncated: false)
    expect(result.evidence.records).to match([include("status" => "paid", "total" => 12)])
    expect(result.evidence.records.first).not_to have_key("tenant_id")
    expect(result.evidence.filters).to eq([{"field" => "status", "operator" => "eq", "value" => "paid"}])
  end

  it "serializes bounded-array predicates into structured evidence" do
    adapter = Maglev::FakePlannerAdapter.new([{"status" => "ready", "ir" => {
      "version" => 1, "root" => "structured_orders", "operation" => "records",
      "scopes" => [], "filters" => [{"field" => "total", "operator" => "between", "value" => [10, 20]}],
      "joins" => [], "sort" => [], "distinct" => false, "limit" => 10
    }}])
    plan = Maglev.plan("Orders between ten and twenty", resource: :structured_orders,
      base_relation: StructuredOrder.where(tenant_id: 1), adapter: adapter)

    result = Maglev.execute(plan)

    expect(result.evidence.filters).to eq([
      {"field" => "total", "operator" => "between", "value" => [10, 20]}
    ])
  end

  it "does not enumerate relation evidence until requested and applies an independent evidence row budget" do
    adapter = Maglev::FakePlannerAdapter.new([{"status" => "ready", "ir" => {
      "version" => 1, "root" => "structured_orders", "operation" => "records", "scopes" => [],
      "filters" => [], "joins" => [], "sort" => [], "distinct" => false, "limit" => 10
    }}])
    plan = Maglev.plan("Orders", resource: :structured_orders,
      base_relation: StructuredOrder.where(tenant_id: 1), adapter: adapter)
    selects = []
    callback = ->(_name, _start, _finish, _id, payload) { selects << payload[:sql] if payload[:sql].start_with?("SELECT") }

    result = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { Maglev.execute(plan, evidence_rows: 1) }
    expect(selects).to be_empty

    records = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { result.evidence.records }
    expect(records.length).to eq(1)
    expect(result.evidence).to be_truncated
    expect(selects.length).to eq(1)
  end

  it "bounds the complete serialized evidence envelope by bytes and reports only safe counts" do
    adapter = Maglev::FakePlannerAdapter.new([{"status" => "ready", "ir" => {
      "version" => 1, "root" => "structured_orders", "operation" => "records", "scopes" => [],
      "filters" => [], "joins" => [], "sort" => [], "distinct" => false, "limit" => 10
    }}])
    plan = Maglev.plan("Orders", resource: :structured_orders,
      base_relation: StructuredOrder.where(tenant_id: 1), adapter: adapter)
    payloads = []
    result = Maglev.execute(plan, evidence_bytes: 100)

    ActiveSupport::Notifications.subscribed(
      ->(_name, _start, _finish, _id, payload) { payloads << payload }, "maglev.structured.execution"
    ) { result.evidence.records }

    serialized = JSON.generate("records" => result.evidence.records, "scalar" => result.evidence.scalar,
      "filters" => result.evidence.filters, "date_ranges" => result.evidence.date_ranges,
      "count" => result.evidence.count, "truncated" => result.evidence.truncated)
    expect(serialized.bytesize).to be <= 100
    expect(result.evidence).to be_truncated
    expect(payloads.last).to include(row_count: 0, evidence_bytes: serialized.bytesize)
    expect(payloads.last.to_s).not_to include("paid", "pending", "old")
  end

  it "returns deterministic aggregate and unsupported results without calling a generation provider" do
    aggregate_adapter = Maglev::FakePlannerAdapter.new([{"status" => "ready", "ir" => {
      "version" => 1, "root" => "structured_orders", "operation" => "aggregate",
      "scopes" => [], "filters" => [], "joins" => [], "sort" => [], "distinct" => false,
      "limit" => 10, "aggregate" => {"function" => "count"}
    }}])
    aggregate_plan = Maglev.plan("How many orders?", resource: :structured_orders,
      base_relation: StructuredOrder.where(tenant_id: 1), adapter: aggregate_adapter)
    unsupported_plan = Maglev::Planner.new(adapter: Maglev::FakePlannerAdapter.new([
      {"status" => "unsupported", "message" => "Writes are unsupported"}
    ])).plan(question: "Delete orders", snapshot: aggregate_plan.validation.snapshot,
      resource: :structured_orders)

    aggregate = Maglev.execute(aggregate_plan)
    unsupported = Maglev.execute(unsupported_plan)

    expect(aggregate).to have_attributes(status: :succeeded, kind: :aggregate, value: 2)
    expect(aggregate.evidence.scalar).to eq(2)
    expect(aggregate.render).to eq("Count: 2")
    expect(unsupported).to have_attributes(status: :unsupported, kind: :none, value: nil)
    expect(unsupported.render).to eq("Writes are unsupported")
  end

  it "correlates safe lifecycle events and an application audit sink without leaking values" do
    events = []
    audits = []
    callback = ->(name, _start, _finish, _id, payload) { events << [name, payload] }
    adapter = Maglev::FakePlannerAdapter.new([{"status" => "ready", "ir" => {
      "version" => 1, "root" => "structured_orders", "operation" => "records",
      "scopes" => [], "filters" => [{"field" => "note", "operator" => "eq", "value" => "value-secret"}],
      "joins" => [], "sort" => [], "distinct" => false, "limit" => 1
    }}])
    Maglev.configuration.audit_sink = ->(event) { audits << event }

    ActiveSupport::Notifications.subscribed(callback, /maglev\.structured\./) do
      plan = Maglev.plan("question-secret", resource: :structured_orders,
        base_relation: StructuredOrder.where(tenant_id: 1), adapter: adapter)
      result = Maglev.execute(plan)
      Maglev::StructuredAnswerComposer.new.compose(result)
    end

    expect(events.map(&:first)).to include(
      "maglev.structured.planning", "maglev.structured.validation", "maglev.structured.compilation",
      "maglev.structured.execution", "maglev.structured.composition"
    )
    trace_ids = events.map { |_name, payload| payload.fetch(:trace_id) }.uniq
    expect(trace_ids.length).to eq(1)
    serialized = [events, audits].inspect
    expect(serialized).not_to include("question-secret", "value-secret", "tenant_id", "SELECT", "provider")
    expect(audits).to all(include(:event, :trace_id, :route, :status))
  ensure
    Maglev.configuration.audit_sink = nil
  end

  def compile(overrides)
    snapshot = Maglev::Registry.snapshot(resources: %i[structured_orders structured_customers])
    validation = validation_for(snapshot, overrides)
    Maglev::QueryCompiler.new(snapshot: snapshot).compile(
      validation: validation,
      base_relation: StructuredOrder.where(tenant_id: 1)
    )
  end

  def validation_for(snapshot, overrides)
    input = {
      "version" => 1, "root" => "structured_orders", "operation" => "records",
      "scopes" => [], "filters" => [], "joins" => [], "sort" => [], "distinct" => false, "limit" => 10
    }.merge(overrides)
    validation = Maglev::QueryValidator.new(snapshot: snapshot, root: :structured_orders).call(input)
    expect(validation).to be_valid
    validation
  end
end
