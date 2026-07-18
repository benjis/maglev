# frozen_string_literal: true

require "spec_helper"
require "maglev"

RSpec.describe Maglev::PlannerEvaluation do
  it "scores semantic IR equivalence instead of exact JSON ordering" do
    expected = {
      "status" => "ready",
      "ir" => {"version" => 1, "root" => "orders", "operation" => "records",
               "filters" => [
                 {"field" => "status", "operator" => "eq", "value" => "paid"},
                 {"field" => "total", "operator" => "gte", "value" => 10}
               ], "joins" => ["customer"], "scopes" => [], "sort" => [], "distinct" => false, "limit" => 10}
    }
    actual = Marshal.load(Marshal.dump(expected))
    actual["ir"]["filters"].reverse!

    report = described_class.score([{"id" => "paid_orders", "expected" => expected, "actual" => actual}])

    expect(report).to include(total: 1, passed: 1, failed: 0, score: 1.0)
    expect(report.fetch(:cases).first).to include(id: "paid_orders", passed: true)
  end

  it "reports status and IR mismatch failure classes" do
    report = described_class.score([
      {"id" => "ambiguous", "expected" => {"status" => "clarification_required"},
       "actual" => {"status" => "unsupported"}},
      {"id" => "count", "expected" => {"status" => "ready", "ir" => {"root" => "orders"}},
       "actual" => {"status" => "ready", "ir" => {"root" => "customers"}}}
    ])

    expect(report.fetch(:cases).map { |item| item[:failure_class] }).to eq(%i[status_mismatch ir_mismatch])
  end
end
