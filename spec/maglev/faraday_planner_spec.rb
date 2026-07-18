# frozen_string_literal: true

require "spec_helper"
require "json"
require "faraday"
require "maglev"

RSpec.describe Maglev::Adapters::FaradayPlanner do
  def connection(&stub)
    Faraday.new { |builder| builder.adapter :test, Faraday::Adapter::Test::Stubs.new(&stub) }
  end

  let(:snapshot) { Maglev::SchemaSnapshot.new(resources: [], paths: []) }
  let(:provider) do
    Maglev::ProviderConfiguration.new(url: "https://planner.example/v1", api_key: "secret", model: "planner-model")
  end

  it "requests strict structured output and returns only provider-neutral planner data" do
    request = nil
    http = connection do |stubs|
      stubs.post("/v1/chat/completions") do |environment|
        request = environment.body.is_a?(Hash) ? JSON.parse(JSON.generate(environment.body)) : JSON.parse(environment.body)
        output = {"status" => "unsupported", "message" => "Outside registered capabilities"}
        [200, {"Content-Type" => "application/json"},
          {choices: [{message: {content: JSON.generate(output)}}]}.to_json]
      end
    end
    adapter = described_class.new(provider: provider, connection: http)

    result = adapter.plan(question: "Delete orders", schema_snapshot: snapshot, constraints: {rows: 5},
      query_ir_schema: Maglev::Planner::QUERY_IR_SCHEMA, repair: nil)

    expect(result).to eq("status" => "unsupported", "message" => "Outside registered capabilities")
    expect(request).to include("model" => "planner-model", "stream" => false)
    expect(request.dig("response_format", "type")).to eq("json_schema")
    expect(request.dig("response_format", "json_schema", "strict")).to be(false)
    prompt = request.fetch("messages").map { |message| message.fetch("content") }.join
    expect(prompt).to include("Delete orders", snapshot.to_json, '"rows":5')
  end

  it "rejects malformed structured content as a permanent provider failure" do
    http = connection do |stubs|
      stubs.post("/v1/chat/completions") do
        [200, {"Content-Type" => "application/json"}, {choices: [{message: {content: "not json"}}]}.to_json]
      end
    end

    expect do
      described_class.new(provider: provider, connection: http).plan(
        question: "question", schema_snapshot: snapshot, constraints: {},
        query_ir_schema: Maglev::Planner::QUERY_IR_SCHEMA
      )
    end.to raise_error(Maglev::PermanentProviderError, /invalid structured output/)
  end
end
