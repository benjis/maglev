# frozen_string_literal: true

require "rails_helper"

class KnowledgeEmbeddingAdapter
  attr_reader :inputs

  def maglev_adapter_id = "knowledge-spec"
  def maglev_adapter_version = "1"

  def initialize
    @inputs = []
  end

  def embed(input)
    @inputs << input
    input.include?("authorized") ? [1.0, 0.0] : [0.0, 1.0]
  end
end

class KnowledgeGenerationAdapter
  attr_reader :prompts

  def initialize(answer)
    @answer = answer
    @prompts = []
  end

  def generate(prompt)
    @prompts << prompt
    @answer
  end
end

class BusinessOutcomeSynthesisAdapter
  attr_reader :requests

  def initialize(output)
    @output = output
    @requests = []
  end

  def synthesize(**request)
    @requests << request
    @output
  end
end

class UntrustedKnowledgeVectorStore < Maglev::VectorStores::Memory
  def search(vector:, filters:, limit:)
    values = filters.to_h
    untrusted_filters = Maglev::VectorStores::MetadataFilter.new(
      owner_model_name: values.fetch(:owner_model_name),
      index_version: values.fetch(:index_version)
    )
    super(vector: vector, filters: untrusted_filters, limit: limit)
  end
end

RSpec.describe "authorized knowledge business questions" do
  around do |example|
    connection = ActiveRecord::Base.connection
    connection.create_table(:knowledge_cases, force: true) do |table|
      table.integer :tenant_id, null: false
      table.string :summary, null: false
      table.string :account_name, null: false
    end
    connection.create_table(:knowledge_metrics, force: true) do |table|
      table.integer :tenant_id, null: false
    end
    example.run
  ensure
    connection&.drop_table(:knowledge_metrics, if_exists: true)
    connection&.drop_table(:knowledge_cases, if_exists: true)
  end

  before do
    stub_const("KnowledgeCase", Class.new(ActiveRecord::Base) do
      self.table_name = "knowledge_cases"
    end)
    stub_const("KnowledgeMetric", Class.new(ActiveRecord::Base) do
      self.table_name = "knowledge_metrics"
    end)
    Maglev::Registry.reset!
    KnowledgeCase.maglev_resource :knowledge_cases do
      knowledge do
        content :summary
        context :account_name
      end
    end
    KnowledgeMetric.maglev_resource :knowledge_metrics do
      queryable { aggregates count: true }
    end

    @authorized = KnowledgeCase.create!(
      tenant_id: 1,
      summary: "authorized customer needs a contract renewal",
      account_name: "Visible Account"
    )
    @unauthorized = KnowledgeCase.create!(
      tenant_id: 2,
      summary: "secret customer is planning a merger",
      account_name: "Hidden Account"
    )
    KnowledgeMetric.create!(tenant_id: 1)
    @original = {
      policy_resolver: Maglev.configuration.policy_resolver,
      planner_adapter: Maglev.configuration.planner_adapter,
      resource_selector_adapter: Maglev.configuration.resource_selector_adapter,
      embedding_adapter: Maglev.configuration.embedding_adapter,
      embedding_dimensions: Maglev.configuration.embedding_dimensions,
      generation_adapter: Maglev.configuration.generation_adapter,
      outcome_synthesis_adapter: Maglev.configuration.outcome_synthesis_adapter,
      vector_store: Maglev.configuration.vector_store
    }

    Maglev.configuration.vector_store = UntrustedKnowledgeVectorStore.new
    Maglev.configuration.embedding_dimensions = 2
    Maglev.configuration.embedding_adapter = KnowledgeEmbeddingAdapter.new
    Maglev.configuration.generation_adapter = KnowledgeGenerationAdapter.new(
      "The authorized customer needs a contract renewal. [S1]"
    )
    [@authorized, @unauthorized].each { |record| Maglev::Indexer.new(record).index }
  end

  after do
    @original.each { |name, value| Maglev.configuration.public_send(:"#{name}=", value) }
    Maglev::Registry.reset!
  end

  it "plans and answers from typed evidence intersected with the authorized relation" do
    user = "opaque-user"
    context = "opaque-context"
    Maglev.configuration.policy_resolver = lambda do |user:, context:|
      {
        knowledge_cases: {
          base_relation: KnowledgeCase.order(:id).limit(1),
          planning_facts: {market: "AU"}
        }
      }
    end
    Maglev.configuration.planner_adapter = Maglev::FakePlannerAdapter.new([{
      "status" => "ready",
      "route" => "knowledge",
      "retrieval" => {
        "limit" => 5,
        "chunks_per_owner" => 1,
        "minimum_similarity" => 0.0
      }
    }])

    outcome = Maglev.ask("Which customer needs a renewal?", user: user, context: context)

    expect(outcome).to be_a(Maglev::BusinessOutcome)
    expect(outcome).to have_attributes(
      status: :answered,
      answer: "The authorized customer needs a contract renewal. [S1]"
    )
    expect(outcome.evidence).to be_a(Maglev::KnowledgeEvidence)
    expect(outcome.evidence.sources.map(&:owner_id)).to eq([@authorized.id])
    expect(outcome.evidence.sources.map(&:citation)).to eq(["S1"])
    expect(outcome.evidence.sources.first.context).to eq("account_name" => "Visible Account")
    expect(outcome.evidence.to_s).not_to include(
      @unauthorized.summary,
      @unauthorized.account_name,
      user,
      context
    )

    planner_request = Maglev.configuration.planner_adapter.requests.fetch(0)
    expect(planner_request.fetch(:schema_snapshot).to_json).to include("knowledge_cases", "summary")
    expect(planner_request.fetch(:planning_facts)).to eq(market: "AU")
    expect(planner_request.to_s).not_to include(user, context, @authorized.summary, @unauthorized.summary)

    generation_prompt = Maglev.configuration.generation_adapter.prompts.fetch(0)
    expect(generation_prompt).to include(@authorized.summary, "Visible Account", "[S1]")
    expect(generation_prompt).not_to include(@unauthorized.summary, "Hidden Account", user, context)
  end

  it "executes structured, knowledge, and hybrid steps through one fixed multi-resource plan" do
    configure_multi_resource_question

    outcome = Maglev.ask("Compare metrics with customer feedback", user: 1, context: "AU")

    expect(outcome).to have_attributes(status: :answered, answer: nil)
    expect(outcome.evidence.map { |item| [item.step_id, item.kind] }).to eq([
      ["metrics", :aggregate],
      ["cases", :semantic_matches],
      ["combined", :hybrid]
    ])
    expect(outcome.evidence[0].value.scalar).to eq(1)
    expect(outcome.evidence[1].value.sources.map(&:owner_id)).to eq([@authorized.id])
    expect(outcome.evidence[2].value).to eq(outcome.evidence.first(2))
  end

  it "returns partial typed Evidence with explicit limitations when one plan branch fails" do
    configure_multi_resource_question
    Maglev.configuration.embedding_adapter = Class.new do
      def embed(*) = raise("embedding unavailable")
    end.new

    outcome = Maglev.ask("Compare metrics with customer feedback", user: 1, context: "AU")

    expect(outcome.status).to eq(:partial)
    expect(outcome.evidence.map { |item| [item.step_id, item.kind] }).to eq([
      ["metrics", :aggregate]
    ])
    expect(outcome.limitations).to include(
      "Step cases failed: Maglev::ConfigurationError",
      "Step combined blocked by failed dependency: cases"
    )
  end

  it "separates evidence-grounded findings, inferences, recommendations, assumptions, and limitations" do
    configure_multi_resource_question
    adapter = BusinessOutcomeSynthesisAdapter.new(
      "answer" => "Renewal risk coincides with one active metric.",
      "findings" => [
        {"text" => "One authorized metric was observed.", "evidence" => ["metrics"], "relationship" => "observed"}
      ],
      "inferences" => [
        {"text" => "The feedback may indicate renewal risk.", "evidence" => ["cases"], "relationship" => "correlation"}
      ],
      "recommendations" => [
        {"text" => "Review the account.", "evidence" => ["metrics", "cases"]}
      ],
      "assumptions" => ["The retrieved feedback remains current."],
      "limitations" => ["Correlation does not establish causation."]
    )
    Maglev.configuration.outcome_synthesis_adapter = adapter

    outcome = Maglev.ask("Compare metrics with customer feedback", user: 1, context: "AU")

    expect(outcome).to have_attributes(
      status: :answered,
      answer: "Renewal risk coincides with one active metric.",
      assumptions: ["The retrieved feedback remains current."],
      limitations: ["Correlation does not establish causation."]
    )
    expect(outcome.findings.first).to have_attributes(
      text: "One authorized metric was observed.", evidence: outcome.evidence.values_at(0),
      relationship: :observed
    )
    expect(outcome.inferences.first).to have_attributes(
      text: "The feedback may indicate renewal risk.", evidence: outcome.evidence.values_at(1),
      relationship: :correlation
    )
    expect(outcome.recommendations.first.evidence).to eq(outcome.evidence.first(2))
    expect(adapter.requests.first.keys).to contain_exactly(:question, :evidence, :limitations)
  end

  it "fails closed when synthesis presents an unsupported or causal finding as fact" do
    configure_multi_resource_question
    Maglev.configuration.outcome_synthesis_adapter = BusinessOutcomeSynthesisAdapter.new(
      "answer" => "Feedback caused the result.",
      "findings" => [
        {"text" => "Feedback caused the result.", "evidence" => ["missing"], "relationship" => "causal"}
      ],
      "inferences" => [],
      "recommendations" => [],
      "assumptions" => [],
      "limitations" => []
    )

    outcome = Maglev.ask("Compare metrics with customer feedback", user: 1, context: "AU")

    expect(outcome).to have_attributes(
      status: :failed,
      answer: nil,
      findings: [],
      warnings: ["The question could not be answered safely."]
    )
  end

  it "does not generate an answer when the authorized relation has no retrieved owners" do
    Maglev.configuration.policy_resolver = lambda do |user:, context:|
      {
        knowledge_cases: {
          base_relation: KnowledgeCase.where(tenant_id: 999),
          planning_facts: {}
        }
      }
    end
    Maglev.configuration.planner_adapter = knowledge_planner

    outcome = Maglev.ask("What is happening?", user: Object.new, context: Object.new)

    expect(outcome).to have_attributes(
      status: :unsupported,
      answer: nil,
      warnings: ["No authorized knowledge evidence was found."]
    )
    expect(outcome.evidence).to be_a(Maglev::KnowledgeEvidence)
    expect(outcome.evidence.sources).to be_empty
    expect(Maglev.configuration.generation_adapter.prompts).to be_empty
  end

  it "exposes authorized typed evidence independently from answer generation" do
    snapshot = Maglev::Registry.snapshot(resources: [:knowledge_cases], authorizer: ->(*) { true })
    plan = Maglev::Planner.new(adapter: knowledge_planner).plan(
      question: "What is happening?",
      snapshot: snapshot,
      resource: :knowledge_cases,
      base_relation: KnowledgeCase.where(tenant_id: 1)
    )

    evidence = Maglev::KnowledgeRetriever.new.retrieve(plan, question: "What is happening?")

    expect(evidence).to be_a(Maglev::KnowledgeEvidence)
    expect(evidence.sources.map(&:owner_id)).to eq([@authorized.id])
    expect(evidence.context).to include(@authorized.summary, "[S1]")
    expect(evidence.context).not_to include(@unauthorized.summary)
    expect(Maglev.configuration.generation_adapter.prompts).to be_empty
  end

  it "fails closed when generation does not cite retrieved evidence" do
    Maglev.configuration.policy_resolver = lambda do |user:, context:|
      {
        knowledge_cases: {
          base_relation: KnowledgeCase.where(tenant_id: 1),
          planning_facts: {}
        }
      }
    end
    Maglev.configuration.planner_adapter = knowledge_planner
    Maglev.configuration.generation_adapter = KnowledgeGenerationAdapter.new(
      "The customer needs a renewal."
    )

    outcome = Maglev.ask("What is happening?", user: Object.new, context: Object.new)

    expect(outcome).to have_attributes(
      status: :failed,
      answer: nil,
      warnings: ["The question could not be answered safely."]
    )
    expect(outcome.evidence).to be_a(Maglev::KnowledgeEvidence)
    expect(outcome.evidence.sources.map(&:owner_id)).to eq([@authorized.id])
  end

  def knowledge_planner
    Maglev::FakePlannerAdapter.new([{
      "status" => "ready",
      "route" => "knowledge",
      "retrieval" => {
        "limit" => 5,
        "chunks_per_owner" => 1,
        "minimum_similarity" => 0.0
      }
    }])
  end

  def configure_multi_resource_question
    Maglev.configuration.policy_resolver = lambda do |user:, context:|
      {
        knowledge_cases: {
          base_relation: KnowledgeCase.where(tenant_id: user),
          planning_facts: {market: context}
        },
        knowledge_metrics: {
          base_relation: KnowledgeMetric.where(tenant_id: user),
          planning_facts: {}
        }
      }
    end
    Maglev.configuration.resource_selector_adapter = Maglev::FakeResourceSelectorAdapter.new([{
      "status" => "selected",
      "resources" => %w[knowledge_metrics knowledge_cases]
    }])
    Maglev.configuration.planner_adapter = Maglev::FakePlannerAdapter.new([{
      "plan" => {
        "version" => 1,
        "steps" => [
          {
            "id" => "metrics", "kind" => "structured", "resource" => "knowledge_metrics",
            "depends_on" => [], "dependency_types" => {},
            "input" => {"ir" => {
              "version" => 2, "root" => "knowledge_metrics", "operation" => "aggregate",
              "scopes" => [], "filters" => [], "joins" => [], "sort" => [],
              "distinct" => false, "limit" => 10,
              "aggregate" => {"function" => "count"}, "group_by" => []
            }}
          },
          {
            "id" => "cases", "kind" => "knowledge", "resource" => "knowledge_cases",
            "depends_on" => [], "dependency_types" => {},
            "input" => {
              "retrieval" => {"limit" => 5, "chunks_per_owner" => 1, "minimum_similarity" => 0.0}
            }
          },
          {
            "id" => "combined", "kind" => "hybrid", "resource" => "knowledge_metrics",
            "depends_on" => %w[metrics cases],
            "dependency_types" => {"metrics" => "aggregate", "cases" => "semantic_matches"},
            "input" => {}
          }
        ]
      }
    }])
  end
end
