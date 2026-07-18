# frozen_string_literal: true

require "spec_helper"
require "maglev"

RSpec.describe "Maglev unified request interface" do
  let(:classifier) { Maglev::FakeRoutingAdapter.new([]) }
  let(:router) { Maglev::Router.new(classifier: classifier) }

  before { Maglev::Registry.reset! }
  after { Maglev::Registry.reset! }

  it "requires an explicit resource/model domain or base relation" do
    expect { Maglev.request("What happened?", mode: :rag, router: router) }
      .to raise_error(Maglev::ConfigurationError, /explicit resource, model, or base relation/)
  end

  it "returns one immutable result envelope for unsupported and clarification routes" do
    unsupported = Maglev.request("Delete orders", mode: :auto, resources: [:orders],
      router: Maglev::Router.new(classifier: Maglev::FakeRoutingAdapter.new([
        {"route" => "unsupported", "confidence" => 0.99, "reasons" => ["write request"]}
      ])))
    clarification = Maglev.request("Show recent items", mode: :auto, resources: [:orders],
      router: Maglev::Router.new(classifier: Maglev::FakeRoutingAdapter.new([
        {"route" => "clarification_required", "confidence" => 0.4, "reasons" => ["ambiguous"]}
      ])))

    expect(unsupported).to have_attributes(status: :unsupported, route: :unsupported, kind: :none,
      value: nil, reasons: ["write request"], confidence: 0.99)
    expect(clarification).to have_attributes(status: :clarification_required,
      route: :clarification_required, kind: :none, value: nil)
    expect(unsupported).to be_frozen
  end

  it "requires one of the two fixed hybrid plan shapes" do
    expect do
      Maglev.request("Customers with overdue invoices who mentioned cancellation",
        mode: :hybrid, resources: %i[customers invoices], router: router)
    end.to raise_error(Maglev::ConfigurationError, /fixed hybrid plan/)
  end

  it "wraps RAG retrieval in the shared result without changing legacy search or ask" do
    model = Class.new
    knowledge = Maglev::KnowledgeConfig.new(model_class: model,
      exposed_attributes: ["summary"], hidden_attributes: [], tags: [])
    Maglev::Registry.register(Maglev::ResourceConfig::Entry.new(
      identifier: "tickets", model_class: model, knowledge: knowledge
    ))
    retrieval = Maglev::RetrievalResult.new(query: "refund", considered: [], selected: [],
      rejected: [], context: "", budgets: {}, reasons: [:no_documents], timings: {}, trace_id: "trace-rag")
    fake_retriever = Object.new
    fake_retriever.define_singleton_method(:retrieve) { |*, **| retrieval }

    result = Maglev.request("refund", mode: :rag, models: [model], router: router,
      retriever_factory: ->(_) { fake_retriever })

    expect(result).to have_attributes(status: :succeeded, route: :rag, kind: :semantic_matches,
      value: retrieval, evidence: [], trace_id: "trace-rag")
  end
end
