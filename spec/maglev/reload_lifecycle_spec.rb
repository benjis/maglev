# frozen_string_literal: true

require "rails_helper"
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

  def content_callback_counts
    {
      active_storage: defined?(ActiveStorage::Attachment) ? ActiveStorage::Attachment._commit_callbacks.count { |callback| callback.filter == :maglev_reindex_attachment_owner } : 0,
      action_text: defined?(ActionText::RichText) ? ActionText::RichText._commit_callbacks.count { |callback| callback.filter == :maglev_reindex_rich_text_owner } : 0
    }
  end
end
