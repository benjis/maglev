# frozen_string_literal: true

require "spec_helper"
require "maglev"

RSpec.describe Maglev::BusinessQuestionPlanValidator do
  let(:resource) do
    Maglev::SchemaSnapshot::Resource.new(
      identifier: "orders", description: "Orders", synonyms: [], table_name: "orders",
      primary_key: "id", sti_base: nil, inheritance_column: "type",
      fields: [], associations: [], scopes: [], aggregates: {count: true},
      limits: {rows: 50, groups: 10}, allow_unscoped_model_queries: false
    )
  end
  let(:snapshot) { Maglev::SchemaSnapshot.new(resources: [resource], paths: []) }
  let(:limits) do
    {
      steps: 2, depth: 1, resources: 1, retrieval_size: 10,
      structured_result_size: 50, total_work: 100
    }
  end
  let(:ir) do
    {
      "version" => 2, "root" => "orders", "operation" => "aggregate",
      "scopes" => [], "filters" => [], "joins" => [], "sort" => [],
      "distinct" => false, "limit" => 10,
      "aggregate" => {"function" => "count"}, "group_by" => []
    }
  end

  it "validates every declared capability before returning a plan" do
    input = {
      "version" => 1,
      "steps" => [{
        "id" => "count", "kind" => "structured", "resource" => "orders",
        "depends_on" => [], "dependency_types" => {}, "input" => {"ir" => ir}
      }]
    }

    plan = described_class.new(
      snapshot: snapshot,
      authorized_resources: {"orders" => {structured: true, knowledge: false}},
      limits: limits
    ).call(input)

    expect(plan.steps.first.input.fetch("ir")).to eq(ir)
  end

  it "rejects prohibited operations instead of returning a partially validated plan" do
    input = {
      "version" => 1,
      "steps" => [{
        "id" => "write", "kind" => "structured", "resource" => "orders",
        "depends_on" => [], "dependency_types" => {}, "input" => {"ir" => ir.merge("operation" => "delete")}
      }]
    }

    expect do
      described_class.new(
        snapshot: snapshot,
        authorized_resources: {"orders" => {structured: true, knowledge: false}},
        limits: limits
      ).call(input)
    end.to raise_error(Maglev::PlanValidationError, /structured step/)
  end

  it "accepts a hybrid step only after its structured and knowledge dependencies are validated" do
    input = {
      "version" => 1,
      "steps" => [
        {
          "id" => "facts", "kind" => "structured", "resource" => "orders",
          "depends_on" => [], "dependency_types" => {}, "input" => {"ir" => ir}
        },
        {
          "id" => "notes", "kind" => "knowledge", "resource" => "orders",
          "depends_on" => [],
          "dependency_types" => {},
          "input" => {
            "retrieval" => {"limit" => 5, "chunks_per_owner" => 1, "minimum_similarity" => nil}
          }
        },
        {
          "id" => "combined", "kind" => "hybrid", "resource" => "orders",
          "depends_on" => %w[facts notes],
          "dependency_types" => {"facts" => "aggregate", "notes" => "semantic_matches"},
          "input" => {}
        }
      ]
    }

    plan = described_class.new(
      snapshot: snapshot,
      authorized_resources: {"orders" => {structured: true, knowledge: true}},
      limits: limits.merge(steps: 3, depth: 2)
    ).call(input)

    expect(plan.execution_order.map(&:id)).to eq(%w[facts notes combined])
  end

  it "rejects a dependency whose declared Evidence type is incompatible with its source step" do
    input = {
      "version" => 1,
      "steps" => [
        {
          "id" => "facts", "kind" => "structured", "resource" => "orders",
          "depends_on" => [], "dependency_types" => {}, "input" => {"ir" => ir}
        },
        {
          "id" => "combined", "kind" => "hybrid", "resource" => "orders",
          "depends_on" => ["facts"],
          "dependency_types" => {"facts" => "semantic_matches"},
          "input" => {}
        }
      ]
    }

    expect do
      described_class.new(
        snapshot: snapshot,
        authorized_resources: {"orders" => {structured: true, knowledge: true}},
        limits: limits.merge(depth: 2)
      ).call(input)
    end.to raise_error(Maglev::PlanValidationError, /incompatible typed dependency/)
  end
end
