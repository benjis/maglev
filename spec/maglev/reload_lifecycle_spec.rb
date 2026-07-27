# frozen_string_literal: true

require "rails_helper"
require "active_job/test_helper"
require "maglev/dependency_graph"
require "maglev/knowledge_registry"

class ReloadTestOwner
  def self.name
    "ReloadTestOwner"
  end

  def self.find(id)
    new(id)
  end
end

RSpec.describe "Rails reload lifecycle" do
  include ActiveJob::TestHelper

  before do
    @original_edges = Maglev::DependencyGraph.instance_variable_get(:@edges)
    Maglev::DependencyGraph.instance_variable_set(:@edges, Hash.new { |hash, klass| hash[klass] = [] })
  end

  after do
    Maglev::DependencyGraph.instance_variable_set(:@edges, @original_edges)
  end

  describe "DependencyGraph.reset!" do
    it "drops all class-keyed edges" do
      edge = Maglev::DependencyGraph::Edge.new(ReloadTestOwner, ReloadTestOwner, "items", "owner", 1)
      Maglev::DependencyGraph.instance_variable_get(:@edges)[ReloadTestOwner] << edge

      Maglev::DependencyGraph.reset!

      expect(Maglev::DependencyGraph.instance_variable_get(:@edges)).to be_empty
    end
  end

  describe "idempotent declaration" do
    it "does not duplicate edges on repeated register calls" do
      allow(Maglev::DependencyGraph).to receive(:install_callbacks)
      schema = Struct.new(:model_class, :relations).new(
        ReloadTestOwner,
        [Struct.new(:related_class, :name, :inverse, :depth).new(ReloadTestOwner, "items", "owner", 1)]
      )

      3.times { Maglev::DependencyGraph.register(schema) }

      edges = Maglev::DependencyGraph.instance_variable_get(:@edges)[ReloadTestOwner]
      expect(edges.size).to eq(1)
    end
  end

  it "rebuilds current dependency edges without duplicate callbacks across prepare cycles" do
    Customer.maglev_config
    Review.maglev_config
    initial_callbacks = Review._commit_callbacks.count { |callback| callback.filter == :maglev_reindex_dependents }

    3.times do
      Rails.application.reloader.prepare!
      edges = Maglev::DependencyGraph.instance_variable_get(:@edges)
      expect(edges.keys).to all(be_a(Class))
      expect(edges.values.flatten).not_to be_empty
      expect(Review._commit_callbacks.count { |callback| callback.filter == :maglev_reindex_dependents }).to eq(initial_callbacks)
    end

    expect(Maglev::KnowledgeRegistry.model_names).to all(be_a(String))
  end

  it "rebuilds current classes, callbacks, and invalidation across three real replacement/prepare cycles" do
    stale_classes = []
    baseline_content_counts = content_callback_counts

    3.times do
      if defined?(ReloadableKnowledgeOwner)
        stale_classes.concat([ReloadableKnowledgeOwner, ReloadableKnowledgeItem])
        Object.send(:remove_const, :ReloadableKnowledgeOwner)
        Object.send(:remove_const, :ReloadableKnowledgeItem)
      end
      define_reloadable_models
      Rails.application.reloader.prepare!

      edges = Maglev::DependencyGraph.instance_variable_get(:@edges)
      expect(edges.keys).to include(ReloadableKnowledgeItem)
      expect(edges.values.flatten.map(&:owner_class)).to include(ReloadableKnowledgeOwner)
      expect(edges.keys & stale_classes).to be_empty
      expect(edges.values.flatten.map(&:owner_class) & stale_classes).to be_empty
      expect(ReloadableKnowledgeOwner._commit_callbacks.count { |callback| %i[maglev_reindex maglev_unindex].include?(callback.filter) }).to eq(2)
      expect(ReloadableKnowledgeItem._commit_callbacks.count { |callback| callback.filter == :maglev_reindex_dependents }).to eq(1)
      expect(content_callback_counts).to eq(baseline_content_counts)

      owner = ReloadableKnowledgeOwner.new(id: 1, name: "Acme")
      item = ReloadableKnowledgeItem.new(id: 2, body: "Changed", owner: owner)
      expect(Maglev::ReindexJob).to receive(:perform_later).with("ReloadableKnowledgeOwner", 1)
      Maglev::DependencyGraph.reindex_dependents_for(item)
    end
  ensure
    Object.send(:remove_const, :ReloadableKnowledgeOwner) if defined?(ReloadableKnowledgeOwner)
    Object.send(:remove_const, :ReloadableKnowledgeItem) if defined?(ReloadableKnowledgeItem)
  end

  it "refreshes reflected schema and independent policies from replacement model definitions" do
    define_reloadable_policy_model(
      field: :name,
      association: :reviews,
      knowledge_content: :name
    )
    Rails.application.reloader.prepare!
    stale_class = ReloadablePolicyCustomer

    expect(reloadable_policy_entry).to have_attributes(model_class: stale_class)
    expect(reloadable_policy_entry.queryable.fields.map(&:name)).to eq(["name"])
    expect(reloadable_policy_entry.queryable.associations.map(&:name)).to eq(["reviews"])
    expect(reloadable_policy_entry.knowledge.content_attributes).to eq(["name"])

    Object.send(:remove_const, :ReloadablePolicyCustomer)
    define_reloadable_policy_model(
      field: :email,
      association: :account,
      knowledge_content: :email
    )
    Rails.application.reloader.prepare!

    current_entry = reloadable_policy_entry
    expect(current_entry.model_class).to equal(ReloadablePolicyCustomer)
    expect(current_entry.model_class).not_to equal(stale_class)
    expect(current_entry.queryable.fields.map(&:name)).to eq(["email"])
    expect(current_entry.queryable.associations.map(&:name)).to eq(["account"])
    expect(current_entry.knowledge.content_attributes).to eq(["email"])
    expect(Maglev::Registry.entries.map(&:model_class)).not_to include(stale_class)
  ensure
    Object.send(:remove_const, :ReloadablePolicyCustomer) if defined?(ReloadablePolicyCustomer)
  end

  it "replaces a prior identifier for the same reloadable model without retaining its stale class" do
    old_model = define_reloadable_identity_model(:legacy_reloadable_customers)
    expect(Maglev::Registry.fetch(:legacy_reloadable_customers).model_class).to equal(old_model)

    Object.send(:remove_const, :ReloadableIdentityCustomer)
    current_model = define_reloadable_identity_model(:reloadable_customers)

    expect(Maglev::Registry.fetch(:legacy_reloadable_customers)).to be_nil
    expect(Maglev::Registry.fetch(:reloadable_customers).model_class).to equal(current_model)
    expect(Maglev::Registry.entries.count { |entry| entry.model_class.name == "ReloadableIdentityCustomer" }).to eq(1)
  ensure
    Object.send(:remove_const, :ReloadableIdentityCustomer) if defined?(ReloadableIdentityCustomer)
  end

  it "deserializes background indexing against the current model class" do
    stale_class = define_reloadable_job_model
    serialized_job = Maglev::ReindexJob.new("ReloadableJobCustomer", 7).serialize

    Object.send(:remove_const, :ReloadableJobCustomer)
    current_class = define_reloadable_job_model
    current_record = current_class.new(id: 7, name: "Current")
    allow(current_class).to receive(:find).with(7).and_return(current_record)
    indexer = instance_double(Maglev::Indexer, index: true)
    expect(Maglev::Indexer).to receive(:new).with(current_record, provider_call: instance_of(Maglev::ProviderCall)).and_return(indexer)

    ActiveJob::Base.deserialize(serialized_job).perform_now

    expect(current_record).to be_a(current_class)
    expect(current_record).not_to be_a(stale_class)
  ensure
    Object.send(:remove_const, :ReloadableJobCustomer) if defined?(ReloadableJobCustomer)
  end

  it "executes a business question against the current resource class after reload" do
    original_policy_resolver = Maglev.configuration.policy_resolver
    original_planner_adapter = Maglev.configuration.planner_adapter
    stale_class = define_reloadable_question_model
    Rails.application.reloader.prepare!

    Object.send(:remove_const, :ReloadableQuestionCustomer)
    current_class = define_reloadable_question_model
    Rails.application.reloader.prepare!
    Maglev.configuration.policy_resolver = lambda do |user:, context:|
      {
        reloadable_question_customers: {
          base_relation: current_class.where(id: -1),
          planning_facts: {user_present: !user.nil?, context_present: !context.nil?}
        }
      }
    end
    Maglev.configuration.planner_adapter = Maglev::FakePlannerAdapter.new([{
      "status" => "ready",
      "ir" => {
        "version" => 2,
        "root" => "reloadable_question_customers",
        "operation" => "aggregate",
        "scopes" => [],
        "filters" => [],
        "joins" => [],
        "sort" => [],
        "distinct" => false,
        "limit" => 10,
        "aggregate" => {"function" => "count"}
      }
    }])

    outcome = Maglev.ask("How many customers?", user: Object.new, context: {})

    expect(outcome).to have_attributes(status: :answered, answer: "Count: 0")
    expect(Maglev::Registry.fetch(:reloadable_question_customers).model_class).to equal(current_class)
    expect(Maglev::Registry.entries.map(&:model_class)).not_to include(stale_class)
  ensure
    Maglev.configuration.policy_resolver = original_policy_resolver
    Maglev.configuration.planner_adapter = original_planner_adapter
    Object.send(:remove_const, :ReloadableQuestionCustomer) if defined?(ReloadableQuestionCustomer)
  end

  it "exposes equivalent capabilities when a model loads before or after preparation" do
    define_reloadable_boot_model
    Rails.application.reloader.prepare!
    eagerly_loaded_capabilities = reloadable_boot_capabilities

    Object.send(:remove_const, :ReloadableBootCustomer)
    Rails.application.reloader.prepare!
    expect(Maglev::Registry.fetch(:reloadable_boot_customers)).to be_nil

    define_reloadable_boot_model
    lazily_loaded_capabilities = reloadable_boot_capabilities

    expect(lazily_loaded_capabilities).to eq(eagerly_loaded_capabilities)
  ensure
    Object.send(:remove_const, :ReloadableBootCustomer) if defined?(ReloadableBootCustomer)
  end

  it "keeps index generation access stable across repeated preparation" do
    generation = Maglev::IndexGeneration.create!(
      generation: "reload-lifecycle",
      status: "active",
      representation_version: Maglev::IndexIdentity::REPRESENTATION_VERSION,
      manifest: {},
      expected_record_count: 0,
      indexed_record_count: 0,
      started_at: Time.now.utc,
      completed_at: Time.now.utc,
      activated_at: Time.now.utc
    )

    3.times do
      Rails.application.reloader.prepare!
      expect(Maglev.index_generation("reload-lifecycle")).to eq(generation.reload)
      expect(Maglev.active_index_generation).to eq(generation.reload)
    end
  ensure
    Maglev::IndexGeneration.where(generation: "reload-lifecycle").delete_all
  end

  it "repairs a missing Action Text callback even when the hook method survives" do
    skip "Action Text is not loaded" unless defined?(ActionText::RichText)

    callback = ActionText::RichText._commit_callbacks.find { |item| item.filter == :maglev_reindex_rich_text_owner }
    ActionText::RichText.skip_callback(:commit, :after, :maglev_reindex_rich_text_owner) if callback
    config = Struct.new(:attached_sources, :rich_text_sources).new([], [Struct.new(:name).new("body")])

    Maglev::ContentSourceGraph.register(config)

    expect(ActionText::RichText.method_defined?(:maglev_reindex_rich_text_owner)).to be true
    expect(ActionText::RichText._commit_callbacks.count { |item| item.filter == :maglev_reindex_rich_text_owner }).to eq(1)
  end

  def define_reloadable_models
    item = Class.new(ActiveRecord::Base) do
      self.table_name = "reviews"
      belongs_to :owner, class_name: "ReloadableKnowledgeOwner", foreign_key: :customer_id, inverse_of: :items
    end
    Object.const_set(:ReloadableKnowledgeItem, item)
    item.maglev_resource(:reload_lifecycle_items) do
      knowledge { expose :body }
    end
    owner = Class.new(ActiveRecord::Base) do
      self.table_name = "customers"
      has_many :items, class_name: "ReloadableKnowledgeItem", foreign_key: :customer_id, inverse_of: :owner
    end
    Object.const_set(:ReloadableKnowledgeOwner, owner)
    owner.maglev_resource(:reload_lifecycle_owners) do
      knowledge do
        expose :name
        include_related :items, depth: 1, limit: 10, inverse: :owner
      end
    end
  end

  def define_reloadable_policy_model(field:, association:, knowledge_content:)
    model = Class.new(ActiveRecord::Base) do
      self.table_name = "customers"
      belongs_to :account
      has_many :reviews, foreign_key: :customer_id
    end
    Object.const_set(:ReloadablePolicyCustomer, model)
    model.maglev_resource(:reloadable_policy_customers) do
      queryable do
        field field
        association association
      end
      knowledge { content knowledge_content }
    end
  end

  def reloadable_policy_entry
    Maglev::Registry.fetch(:reloadable_policy_customers)
  end

  def define_reloadable_identity_model(identifier)
    model = Class.new(ActiveRecord::Base) do
      self.table_name = "customers"
    end
    Object.const_set(:ReloadableIdentityCustomer, model)
    model.maglev_resource(identifier)
    model
  end

  def define_reloadable_job_model
    model = Class.new(ActiveRecord::Base) do
      self.table_name = "customers"
    end
    Object.const_set(:ReloadableJobCustomer, model)
    model.maglev_resource(:reloadable_job_customers) do
      knowledge { content :name }
    end
    model
  end

  def define_reloadable_boot_model
    model = Class.new(ActiveRecord::Base) do
      self.table_name = "customers"
      has_many :reviews, foreign_key: :customer_id
    end
    Object.const_set(:ReloadableBootCustomer, model)
    model.maglev_resource(:reloadable_boot_customers) do
      queryable do
        field :name
        association :reviews
      end
      knowledge { content :name }
    end
  end

  def define_reloadable_question_model
    model = Class.new(ActiveRecord::Base) do
      self.table_name = "customers"
    end
    Object.const_set(:ReloadableQuestionCustomer, model)
    model.maglev_resource(:reloadable_question_customers) do
      queryable { aggregates count: true }
    end
    model
  end

  def reloadable_boot_capabilities
    entry = Maglev::Registry.fetch(:reloadable_boot_customers)
    {
      identifier: entry.identifier,
      fields: entry.queryable.fields.map(&:name),
      associations: entry.queryable.associations.map(&:name),
      content: entry.knowledge.content_attributes
    }
  end

  def content_callback_counts
    {
      active_storage: defined?(ActiveStorage::Attachment) ? ActiveStorage::Attachment._commit_callbacks.count { |callback| callback.filter == :maglev_reindex_attachment_owner } : 0,
      action_text: defined?(ActionText::RichText) ? ActionText::RichText._commit_callbacks.count { |callback| callback.filter == :maglev_reindex_rich_text_owner } : 0
    }
  end
end
