# frozen_string_literal: true

require "spec_helper"
require "maglev"

RSpec.describe Maglev::StructuredAnswerComposer do
  let(:aggregate) { Struct.new(:function).new(:count) }
  let(:ir) { Struct.new(:aggregate, :operation).new(aggregate, :records) }
  let(:plan) { Struct.new(:ir, :clarification, :resource).new(ir, nil, "orders") }
  let(:evidence) do
    Maglev::StructuredEvidence.new(records: [{"status" => "paid", "total" => 12}], count: 1)
  end
  let(:result) do
    Maglev::StructuredResult.new(status: :succeeded, kind: :relation, value: Object.new,
      evidence: evidence, plan: plan, trace_id: "trace-123")
  end

  it "sends only bounded serialized evidence to generation and renders selected evidence paths" do
    adapter = Class.new do
      attr_reader :input

      def generate(input)
        @input = input
        {"claim_paths" => [["records", 0, "status"], ["records", 0, "total"]]}
      end
    end.new

    answer = described_class.new(generation_adapter: adapter).compose(result)

    expect(answer).to eq("Status: paid. Total: 12.")
    expect(adapter.input).to include('"status":"paid"', '"total":12')
    expect(adapter.input).not_to include("question", "prompt", "tenant")
  end

  it "rejects generated claim paths that are absent from structured evidence" do
    adapter = Class.new do
      def generate(*) = {"claim_paths" => [["records", 0, "secret-token"]]}
    end.new

    expect { described_class.new(generation_adapter: adapter).compose(result) }
      .to raise_error(Maglev::GroundingError, /absent from structured evidence/)
  end

  it "deeply freezes nested structured evidence values" do
    nested = {"metadata" => {"tags" => ["paid"]}}
    frozen_evidence = Maglev::StructuredEvidence.new(records: [nested])

    expect { frozen_evidence.records.first.fetch("metadata").fetch("tags") << "secret" }
      .to raise_error(FrozenError)
  end

  it "materializes lazy evidence only once across concurrent readers" do
    calls = 0
    evidence = Maglev::StructuredEvidence.new(loader: lambda {
      sleep(0.01)
      calls += 1
      [[{"status" => "paid"}], 1, false]
    })

    threads = 4.times.map { Thread.new { evidence.records } }
    expect(threads.map(&:value)).to all(eq([{"status" => "paid"}]))
    expect(calls).to eq(1)
  end

  it "uses deterministic rendering when no generation adapter is supplied" do
    expect(described_class.new.compose(result)).to eq("status | total\npaid | 12")
  end

  it "never calls generation for unsupported results" do
    adapter = Class.new { def generate(*) = raise("must not generate") }.new
    unsupported = Maglev::StructuredResult.new(status: :unsupported, kind: :none,
      warnings: ["Writes are unsupported"], plan: plan, trace_id: "trace-123")

    expect(described_class.new(generation_adapter: adapter).compose(unsupported)).to eq("Writes are unsupported")
  end
end
