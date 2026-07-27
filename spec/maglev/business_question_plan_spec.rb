# frozen_string_literal: true

require "spec_helper"
require "maglev"

RSpec.describe Maglev::BusinessQuestionPlan do
  let(:input) do
    {
      "version" => 1,
      "steps" => [
        {
          "id" => "revenue",
          "kind" => "structured",
          "resource" => "orders",
          "depends_on" => [],
          "dependency_types" => {},
          "input" => {"ir" => {"operation" => "aggregate", "limit" => 50}}
        },
        {
          "id" => "feedback",
          "kind" => "knowledge",
          "resource" => "tickets",
          "depends_on" => [],
          "dependency_types" => {},
          "input" => {"retrieval" => {"limit" => 5}}
        },
        {
          "id" => "outcome",
          "kind" => "hybrid",
          "resource" => "orders",
          "depends_on" => %w[revenue feedback],
          "dependency_types" => {"revenue" => "aggregate", "feedback" => "semantic_matches"},
          "input" => {}
        }
      ]
    }
  end

  it "represents a finite typed DAG as an immutable serializable value" do
    plan = described_class.build(
      input,
      authorized_resources: %w[orders tickets],
      limits: {
        steps: 3,
        depth: 2,
        resources: 2,
        retrieval_size: 10,
        structured_result_size: 100,
        total_work: 120
      }
    )

    expect(plan.version).to eq(1)
    expect(plan.steps.map(&:kind)).to eq(%i[structured knowledge hybrid])
    expect(plan.execution_order.map(&:id)).to eq(%w[revenue feedback outcome])
    expect(plan.to_h).to eq(
      "version" => 1,
      "budgets" => {
        "steps" => 3,
        "depth" => 2,
        "resources" => 2,
        "retrieval_size" => 10,
        "structured_result_size" => 100,
        "total_work" => 120
      },
      "steps" => [
        input.fetch("steps")[0].merge(
          "expected_evidence" => {"kind" => "aggregate", "maximum" => 50}
        ),
        input.fetch("steps")[1].merge(
          "expected_evidence" => {"kind" => "semantic_matches", "maximum" => 5}
        ),
        input.fetch("steps")[2].merge(
          "expected_evidence" => {"kind" => "hybrid", "maximum" => 2}
        )
      ]
    )
    expect(plan).not_to be_validated
    expect(plan).to be_frozen
    expect(plan.steps).to all(be_frozen)
    expect(plan.to_h).to be_frozen
  end

  it "rejects cycles, invalid references, unauthorized resources, and limit violations" do
    cases = {
      "cycle" => input.merge("steps" => input.fetch("steps").map.with_index do |step, index|
        step.merge(
          "depends_on" => (index.zero? ? ["outcome"] : step.fetch("depends_on")),
          "dependency_types" => (index.zero? ? {"outcome" => "hybrid"} : step.fetch("dependency_types"))
        )
      end),
      "invalid dependency" => input.merge("steps" => [
        input.fetch("steps").first.merge(
          "depends_on" => ["missing"], "dependency_types" => {"missing" => "aggregate"}
        ),
        *input.fetch("steps").drop(1)
      ]),
      "unauthorized resource" => input.merge("steps" => [
        input.fetch("steps").first.merge("resource" => "secrets"),
        *input.fetch("steps").drop(1)
      ])
    }
    limits = {
      steps: 3, depth: 2, resources: 2, retrieval_size: 10,
      structured_result_size: 100, total_work: 120
    }

    cases.each_value do |invalid|
      expect do
        described_class.build(invalid, authorized_resources: %w[orders tickets], limits: limits)
      end.to raise_error(Maglev::PlanValidationError)
    end

    expect do
      described_class.build(input, authorized_resources: %w[orders tickets],
        limits: limits.merge(total_work: 10))
    end.to raise_error(Maglev::PlanValidationError, /total work/)

    excessive_retrieval = input.merge("steps" => [
      input.fetch("steps")[1].merge(
        "input" => {
          "retrieval" => {"limit" => 5, "chunks_per_owner" => 3, "minimum_similarity" => nil}
        }
      )
    ])
    expect do
      described_class.build(excessive_retrieval, authorized_resources: %w[orders tickets],
        limits: limits)
    end.to raise_error(Maglev::PlanValidationError, /retrieval limit/)
  end
end
