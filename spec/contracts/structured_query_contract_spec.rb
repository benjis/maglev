# frozen_string_literal: true

require "json"
require "spec_helper"

RSpec.describe "Structured-query contracts" do
  let(:contract_path) { File.expand_path("../fixtures/structured_query/query_ir_v1.json", __dir__) }
  let(:scenarios_path) { File.expand_path("../fixtures/structured_query/adversarial_scenarios.json", __dir__) }
  let(:contract) { JSON.parse(File.read(contract_path)) }
  let(:scenarios) { JSON.parse(File.read(scenarios_path)) }

  it "fixes the stable Query IR v1 serialization vocabulary" do
    expect(contract.fetch("query_ir")).to include(
      "version" => 1,
      "root" => "orders",
      "operation" => "records"
    )
    expect(contract.dig("query_ir", "filters", 0)).to eq(
      "field" => "status",
      "operator" => "eq",
      "value" => "paid"
    )
    expect(contract.dig("query_ir", "sort", 0)).to eq("field" => "created_at", "direction" => "desc")
    expect(contract.dig("query_ir", "limit")).to eq(25)
  end

  it "defines plan and result statuses independently from result kinds" do
    expect(contract.fetch("plan_statuses")).to eq(%w[ready clarification_required unsupported invalid])
    expect(contract.fetch("result_statuses")).to eq(%w[succeeded clarification_required unsupported failed])
    expect(contract.fetch("result_kinds")).to eq(%w[relation scalar aggregate rag_answer hybrid_answer none])
  end

  it "defines typed validation failures without echoing sensitive values" do
    error = contract.fetch("validation_error")

    expect(error).to include(
      "code" => "unregistered_field",
      "path" => ["filters", 0, "field"]
    )
    expect(error.fetch("details")).to eq("resource" => "orders", "field" => "secret_token")
    expect(error).not_to have_key("value")
  end

  it "requires compilation to preserve the caller-supplied base relation" do
    policy = contract.fetch("base_relation_policy")

    expect(policy).to include("application_calls" => "required", "model_all_default" => "deny")
    expect(policy.fetch("compiler_prohibitions")).to include("unscoped", "root_model_switch", "constraint_removal")
  end

  it "covers every required adversarial security scenario" do
    expect(scenarios.map { |scenario| scenario.fetch("id") }).to contain_exactly(
      "tenant_escape",
      "model_switching",
      "sensitive_field",
      "prompt_injection",
      "expensive_query",
      "unsupported_request"
    )
    expect(scenarios).to all(include("expected_status", "required_control", "must_not"))
  end
end
