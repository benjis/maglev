# frozen_string_literal: true

require "spec_helper"
require "maglev"

RSpec.describe Maglev::BusinessQuestionPlanExecutor do
  it "runs independent ready steps concurrently without exceeding its configured bound" do
    steps = %w[first second third].map do |id|
      {
        "id" => id, "kind" => "structured", "resource" => "orders",
        "depends_on" => [], "dependency_types" => {},
        "input" => {"ir" => aggregate_ir}
      }
    end
    plan = validated_plan(steps)
    started = Queue.new
    release = Queue.new
    executor = described_class.new(
      structured_runner: lambda do |step|
        started << step.id
        release.pop
        structured_evidence(step.id)
      end,
      knowledge_runner: ->(_step) { raise "not used" },
      max_concurrency: 2
    )

    execution_thread = Thread.new { executor.execute(plan) }
    first_wave = [started.pop, started.pop]
    expect(first_wave).to contain_exactly("first", "second")
    expect(started).to be_empty

    2.times { release << true }
    expect(Timeout.timeout(1) { started.pop }).to eq("third")
    release << true
    execution = execution_thread.value

    expect(execution.evidence.map(&:step_id)).to eq(%w[first second third])
  end

  it "starts a newly ready dependent as soon as a concurrency slot is available" do
    plan = validated_plan([
      {
        "id" => "fast", "kind" => "structured", "resource" => "orders",
        "depends_on" => [], "dependency_types" => {}, "input" => {"ir" => aggregate_ir}
      },
      {
        "id" => "slow", "kind" => "structured", "resource" => "orders",
        "depends_on" => [], "dependency_types" => {}, "input" => {"ir" => aggregate_ir}
      },
      {
        "id" => "dependent", "kind" => "structured", "resource" => "orders",
        "depends_on" => ["fast"], "dependency_types" => {"fast" => "aggregate"},
        "input" => {"ir" => aggregate_ir}
      }
    ])
    started = Queue.new
    release_slow = Queue.new
    executor = described_class.new(
      structured_runner: lambda do |step|
        started << step.id
        release_slow.pop if step.id == "slow"
        structured_evidence(step.id)
      end,
      knowledge_runner: ->(_step) { raise "not used" },
      max_concurrency: 2
    )

    execution_thread = Thread.new { executor.execute(plan) }
    first_wave = [started.pop, started.pop]
    expect(first_wave).to contain_exactly("fast", "slow")
    expect(Timeout.timeout(1) { started.pop }).to eq("dependent")
    release_slow << true

    expect(execution_thread.value.status).to eq(:complete)
  end

  it "returns partial Evidence and blocks dependents when one independent branch fails" do
    plan = validated_plan([
      {
        "id" => "complete", "kind" => "structured", "resource" => "orders",
        "depends_on" => [], "dependency_types" => {}, "input" => {"ir" => aggregate_ir}
      },
      {
        "id" => "failed", "kind" => "structured", "resource" => "orders",
        "depends_on" => [], "dependency_types" => {}, "input" => {"ir" => aggregate_ir}
      },
      {
        "id" => "blocked", "kind" => "structured", "resource" => "orders",
        "depends_on" => ["failed"], "dependency_types" => {"failed" => "aggregate"},
        "input" => {"ir" => aggregate_ir}
      }
    ])
    executor = described_class.new(
      structured_runner: lambda do |step|
        raise "branch failed" if step.id == "failed"
        raise "blocked step executed" if step.id == "blocked"

        structured_evidence(:complete)
      end,
      knowledge_runner: ->(_step) { raise "not used" },
      max_concurrency: 2
    )

    execution = executor.execute(plan)

    expect(execution.status).to eq(:partial)
    expect(execution.evidence.map(&:step_id)).to eq(["complete"])
    expect(execution.step_states.map { |state| [state.step_id, state.status] }).to eq([
      ["complete", :succeeded],
      ["failed", :failed],
      ["blocked", :blocked]
    ])
    expect(execution.limitations).to include(
      "Step failed failed: RuntimeError",
      "Step blocked blocked by failed dependency: failed"
    )
  end

  it "records timed out steps and blocks their dependents deterministically" do
    plan = validated_plan([
      {
        "id" => "slow", "kind" => "structured", "resource" => "orders",
        "depends_on" => [], "dependency_types" => {}, "input" => {"ir" => aggregate_ir}
      },
      {
        "id" => "dependent", "kind" => "structured", "resource" => "orders",
        "depends_on" => ["slow"], "dependency_types" => {"slow" => "aggregate"},
        "input" => {"ir" => aggregate_ir}
      }
    ])
    executor = described_class.new(
      structured_runner: ->(_step) { Queue.new.pop },
      knowledge_runner: ->(_step) { raise "not used" },
      step_timeout: 0.01
    )

    execution = executor.execute(plan)

    expect(execution.status).to eq(:failed)
    expect(execution.step_states.map { |state| [state.step_id, state.status] }).to eq([
      ["slow", :timed_out],
      ["dependent", :blocked]
    ])
    expect(execution.limitations).to include(
      "Step slow timed out",
      "Step dependent blocked by failed dependency: slow"
    )
  end

  it "cancels unstarted steps without invoking their runners" do
    plan = validated_plan([
      {
        "id" => "cancelled", "kind" => "structured", "resource" => "orders",
        "depends_on" => [], "dependency_types" => {}, "input" => {"ir" => aggregate_ir}
      }
    ])
    executor = described_class.new(
      structured_runner: ->(_step) { raise "cancelled step executed" },
      knowledge_runner: ->(_step) { raise "not used" }
    )

    execution = executor.execute(plan, cancellation: -> { true })

    expect(execution.status).to eq(:failed)
    expect(execution.evidence).to be_empty
    expect(execution.step_states.map { |state| [state.step_id, state.status] }).to eq([
      ["cancelled", :cancelled]
    ])
    expect(execution.limitations).to eq(["Step cancelled cancelled"])
  end

  it "cancels running work and does not start a later ready step" do
    plan = validated_plan(%w[first second third].map do |id|
      {
        "id" => id, "kind" => "structured", "resource" => "orders",
        "depends_on" => [], "dependency_types" => {}, "input" => {"ir" => aggregate_ir}
      }
    end)
    started = Queue.new
    cancelled = false
    executor = described_class.new(
      structured_runner: lambda do |step|
        started << step.id
        Queue.new.pop
      end,
      knowledge_runner: ->(_step) { raise "not used" },
      max_concurrency: 2
    )

    execution_thread = Thread.new { executor.execute(plan, cancellation: -> { cancelled }) }
    expect([started.pop, started.pop]).to contain_exactly("first", "second")
    cancelled = true
    execution = Timeout.timeout(1) { execution_thread.value }

    expect(started).to be_empty
    expect(execution.step_states.map(&:status)).to eq(%i[cancelled cancelled cancelled])
  end

  it "fails a step whose runtime output does not match its declared Evidence type" do
    plan = validated_plan([
      {
        "id" => "invalid", "kind" => "structured", "resource" => "orders",
        "depends_on" => [], "dependency_types" => {}, "input" => {"ir" => aggregate_ir}
      }
    ])
    executor = described_class.new(
      structured_runner: ->(_step) { "not structured Evidence" },
      knowledge_runner: ->(_step) { raise "not used" }
    )

    execution = executor.execute(plan)

    expect(execution.status).to eq(:failed)
    expect(execution.step_states.first.status).to eq(:failed)
    expect(execution.limitations).to eq(["Step invalid produced incompatible Evidence"])
  end

  it "executes only declared steps and carries structured and knowledge evidence into a hybrid step" do
    input = {
      "version" => 1,
      "steps" => [
        {
          "id" => "revenue", "kind" => "structured", "resource" => "orders",
          "depends_on" => [],
          "dependency_types" => {},
          "input" => {
            "ir" => {
              "version" => 2, "root" => "orders", "operation" => "aggregate",
              "scopes" => [], "filters" => [], "joins" => [], "sort" => [],
              "distinct" => false, "limit" => 5,
              "aggregate" => {"function" => "count"}, "group_by" => []
            }
          }
        },
        {
          "id" => "feedback", "kind" => "knowledge", "resource" => "tickets",
          "depends_on" => [],
          "dependency_types" => {},
          "input" => {"retrieval" => {"limit" => 3, "chunks_per_owner" => 1, "minimum_similarity" => nil}}
        },
        {
          "id" => "outcome", "kind" => "hybrid", "resource" => "orders",
          "depends_on" => %w[revenue feedback],
          "dependency_types" => {"revenue" => "aggregate", "feedback" => "semantic_matches"},
          "input" => {}
        }
      ]
    }
    limits = {
      steps: 3, depth: 2, resources: 2, retrieval_size: 10,
      structured_result_size: 10, total_work: 30
    }
    resource = Maglev::SchemaSnapshot::Resource.new(
      identifier: "orders", description: "Orders", synonyms: [], table_name: "orders",
      primary_key: "id", sti_base: nil, inheritance_column: "type",
      fields: [], associations: [], scopes: [], aggregates: {count: true},
      limits: {rows: 10}, allow_unscoped_model_queries: false
    )
    ticket_resource = resource.dup
    ticket_resource.identifier = "tickets"
    snapshot = Maglev::SchemaSnapshot.new(resources: [resource, ticket_resource], paths: [])
    plan = Maglev::BusinessQuestionPlanValidator.new(
      snapshot: snapshot,
      authorized_resources: {
        "orders" => {structured: true, knowledge: false},
        "tickets" => {structured: true, knowledge: true}
      },
      limits: limits
    ).call(input)
    calls = []
    executor = described_class.new(
      structured_runner: lambda do |step|
        calls << step.id
        structured_evidence(:revenue)
      end,
      knowledge_runner: lambda do |step|
        calls << step.id
        knowledge_evidence
      end
    )

    result = executor.execute(plan)

    expect(calls).to eq(%w[revenue feedback])
    expect(result.evidence.map { |item| [item.step_id, item.kind] }).to eq([
      ["revenue", :aggregate],
      ["feedback", :semantic_matches],
      ["outcome", :hybrid]
    ])
    expect(result.evidence.last.value).to eq(result.evidence.first(2))
    expect(result.evidence).to all(be_frozen)
    expect(result).to be_frozen
  end

  it "rejects a structurally valid plan that has not passed capability validation" do
    plan = Maglev::BusinessQuestionPlan.build(
      {
        "version" => 1,
        "steps" => [{
          "id" => "step", "kind" => "knowledge", "resource" => "orders",
          "depends_on" => [], "dependency_types" => {},
          "input" => {"retrieval" => {"limit" => 1}}
        }]
      },
      authorized_resources: ["orders"],
      limits: {
        steps: 1, depth: 1, resources: 1, retrieval_size: 1,
        structured_result_size: 1, total_work: 3
      }
    )
    executor = described_class.new(
      structured_runner: ->(_step) { raise "must not execute" },
      knowledge_runner: ->(_step) { raise "must not execute" }
    )

    expect { executor.execute(plan) }.to raise_error(
      Maglev::PlanValidationError, /validated Business Question Plan/
    )
  end

  def aggregate_ir
    {
      "version" => 2, "root" => "orders", "operation" => "aggregate",
      "scopes" => [], "filters" => [], "joins" => [], "sort" => [],
      "distinct" => false, "limit" => 1,
      "aggregate" => {"function" => "count"}, "group_by" => []
    }
  end

  def validated_plan(steps)
    resource = Maglev::SchemaSnapshot::Resource.new(
      identifier: "orders", description: "Orders", synonyms: [], table_name: "orders",
      primary_key: "id", sti_base: nil, inheritance_column: "type",
      fields: [], associations: [], scopes: [], aggregates: {count: true},
      limits: {rows: 10}, allow_unscoped_model_queries: false
    )
    Maglev::BusinessQuestionPlanValidator.new(
      snapshot: Maglev::SchemaSnapshot.new(resources: [resource], paths: []),
      authorized_resources: {"orders" => {structured: true, knowledge: false}},
      limits: {
        steps: 3, depth: 2, resources: 1, retrieval_size: 1,
        structured_result_size: 3, total_work: 10
      }
    ).call("version" => 1, "steps" => steps)
  end

  def structured_evidence(scalar = 1)
    Maglev::StructuredEvidence.new(scalar: scalar)
  end

  def knowledge_evidence
    Maglev::KnowledgeEvidence.new(
      sources: [], context: "", reasons: [], budgets: {}, trace_id: "trace"
    )
  end
end
