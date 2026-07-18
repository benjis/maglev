# frozen_string_literal: true

require "spec_helper"
require "maglev"

RSpec.describe Maglev::Router do
  before { Maglev::Registry.reset! }
  after { Maglev::Registry.reset! }

  it "honors an explicit mode without invoking the classifier" do
    classifier = Class.new do
      def classify(**) = raise("classifier must not be invoked")
    end.new
    request = Maglev::Request.new(question: "How many paid orders?", mode: :structured,
      resources: [:orders])

    decision = described_class.new(classifier: classifier).route(request)

    expect(decision).to have_attributes(route: :structured, confidence: 1.0,
      reasons: ["explicit_mode"])
    expect(decision).to be_frozen
  end

  it "automatically returns every route status from bounded registered capability summaries" do
    knowledge = Maglev::KnowledgeConfig.new(model_class: Class.new,
      exposed_attributes: ["title"], hidden_attributes: [], tags: [])
    Maglev::Registry.register(Maglev::ResourceConfig::Entry.new(
      identifier: "orders", model_class: Class.new, description: "Customer orders",
      queryable: nil, knowledge: knowledge
    ))
    outputs = [
      {"route" => "structured", "confidence" => 0.91, "reasons" => ["aggregate request"]},
      {"route" => "rag", "confidence" => 0.88, "reasons" => ["knowledge question"]},
      {"route" => "hybrid", "confidence" => 0.77, "reasons" => ["needs both"]},
      {"route" => "unsupported", "confidence" => 0.99, "reasons" => ["write request"]},
      {"route" => "clarification_required", "confidence" => 0.5, "reasons" => ["ambiguous intent"]}
    ]
    classifier = Maglev::FakeRoutingAdapter.new(outputs)
    router = described_class.new(classifier: classifier)

    decisions = outputs.map do
      router.route(Maglev::Request.new(question: "request text", resources: [:orders]))
    end

    expect(decisions.map(&:route)).to eq(%i[structured rag hybrid unsupported clarification_required])
    expect(decisions.first).to have_attributes(confidence: 0.91, reasons: ["aggregate request"],
      resources: ["orders"])
    expect(classifier.requests.first.fetch(:capabilities)).to eq([
      {identifier: "orders", description: "Customer orders", structured: false, rag: true,
       fields: [], sources: ["title"]}
    ])
    expect(classifier.requests.first.to_s).not_to include("record content")
  end

  it "never allows a classifier decision to add registered resources" do
    classifier = Maglev::FakeRoutingAdapter.new([
      {"route" => "structured", "confidence" => 0.9, "reasons" => [], "resources" => ["secret"]}
    ])

    decision = described_class.new(classifier: classifier).route(
      Maglev::Request.new(question: "orders", resources: [:orders])
    )

    expect(decision.resources).to eq(["orders"])
  end

  it "fails clearly when automatic routing has no configured adapter" do
    expect do
      described_class.new(classifier: nil).route(
        Maglev::Request.new(question: "orders", resources: [:orders])
      )
    end.to raise_error(Maglev::ConfigurationError, /routing adapter is not configured/)
  end
end
