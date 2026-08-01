# frozen_string_literal: true

require "spec_helper"
require "rake"
require "tmpdir"
require "maglev"
require "maglev/active_record_extension"

class TaskRecord
  def self.name = "TaskRecord"
  def self.attribute_names = %w[id name]

  def self.after_commit(*)
  end

  def self.find_each
    yield new(1)
    yield new(2)
  end

  include Maglev::ActiveRecordExtension

  maglev_resource :rake_task_records do
    knowledge do
      expose :name
    end
  end

  attr_reader :id

  def name = "Task #{@id}"

  def initialize(id)
    @id = id
  end
end

RSpec.describe "Maglev rake tasks" do
  before do
    Rake.application = Rake::Application.new
    task = Rake::Task.define_task(:environment)
    task.clear_actions
    load File.expand_path("../../lib/tasks/maglev.rake", __dir__)
  end

  after do
    Rake.application = nil
  end

  it "reindexes a named model safely and repeatably" do
    indexer = instance_double(Maglev::Indexer, index: true)
    allow(Maglev::Indexer).to receive(:new).and_return(indexer)

    2.times do
      Rake::Task["maglev:reindex"].reenable
      Rake::Task["maglev:reindex"].invoke("TaskRecord")
    end

    expect(indexer).to have_received(:index).exactly(4).times
  end

  it "re-embeds records after the application index version changes" do
    original = Maglev.configuration
    configuration = Maglev::Configuration.new
    adapter = Class.new do
      attr_reader :calls

      def initialize = @calls = 0
      def maglev_adapter_id = "test.rake"
      def maglev_adapter_version = "1"

      def embed(_text)
        @calls += 1
        [1.0, 0.0]
      end
    end.new
    configuration.embedding_adapter = adapter
    configuration.embedding_dimensions = 2
    store = Maglev::VectorStores::Memory.new
    configuration.vector_store = store
    Maglev.instance_variable_set(:@configuration, configuration)

    Rake::Task["maglev:reindex"].invoke("TaskRecord")
    first_documents = store.search(vector: [1.0, 0.0], filters: {owner_model_name: "TaskRecord"}, limit: 10)
    first_version = first_documents.first.index_version
    expect(adapter.calls).to eq(2)

    Rake::Task["maglev:reindex"].reenable
    Rake::Task["maglev:reindex"].invoke("TaskRecord")
    expect(adapter.calls).to eq(2)

    configuration.application_index_version = "2"
    Rake::Task["maglev:reindex"].reenable
    Rake::Task["maglev:reindex"].invoke("TaskRecord")

    expect(adapter.calls).to eq(4)
    current_documents = store.search(vector: [1.0, 0.0], filters: {owner_model_name: "TaskRecord"}, limit: 10)
    expect(current_documents.first.index_version).not_to eq(first_version)
  ensure
    Maglev.instance_variable_set(:@configuration, original)
  end

  it "prints configured model status" do
    allow(ActiveRecord::Base).to receive(:descendants).and_return([TaskRecord])

    expect do
      Rake::Task["maglev:status"].invoke
    end.to output(/TaskRecord/).to_stdout
  end

  it "scores a provider-free planner evaluation corpus" do
    path = File.expand_path("../dummy/evaluations/planner_v1.json", __dir__)

    expect do
      Rake::Task["maglev:evaluate_planner"].invoke(path)
    end.to output(/Planner evaluation v1: 12\/12 passed \(100.0%\)/).to_stdout
  end

  describe "semantic snapshot tasks" do
    around do |example|
      original = Maglev.configuration
      Dir.mktmpdir("maglev-semantic-task") do |directory|
        @semantic_root = Pathname(directory)
        @semantic_root.join("app/models").mkpath
        @semantic_root.join("app/models/customer.rb").write(<<~RUBY)
          class Customer
            semantic_term :active_customer
          end
        RUBY
        configuration = Maglev::Configuration.new
        configuration.semantic_snapshot_path = @semantic_root.join("custom/snapshot.yml")
        Maglev.instance_variable_set(:@configuration, configuration)
        Dir.chdir(@semantic_root) { example.run }
      end
    ensure
      Maglev.instance_variable_set(:@configuration, original)
    end

    before do
      allow(Maglev::Registry).to receive(:entries).and_return([])
    end

    def invoke_semantic_task(name)
      task = Rake::Task["maglev:semantics:#{name}"]
      task.reenable
      task.invoke
    end

    it "builds reproducibly and validates without modifying the artifact" do
      path = Maglev.configuration.semantic_snapshot_path

      expect { invoke_semantic_task(:build) }.to output(/Built semantic snapshot/).to_stdout
      first = path.binread
      first_mtime = path.mtime
      expect(Maglev::SemanticSnapshot.load(first).build_input_fingerprint).to start_with("sha256:")

      expect { invoke_semantic_task(:build) }.to output(/Built semantic snapshot/).to_stdout
      expect(path.binread).to eq(first)

      expect { invoke_semantic_task(:validate) }.to output(/Valid semantic snapshot/).to_stdout
      expect(path.binread).to eq(first)
      expect(path.mtime).to be >= first_mtime
    end

    it "preserves the prior artifact when discovery fails" do
      path = Maglev.configuration.semantic_snapshot_path
      path.dirname.mkpath
      path.write("previous-valid-artifact")
      allow(Maglev::SemanticDiscovery).to receive(:new).and_raise("scan failed")

      expect { invoke_semantic_task(:build) }.to raise_error("scan failed")
      expect(path.binread).to eq("previous-valid-artifact")
    end

    it "preserves the prior artifact when atomic replacement fails" do
      path = Maglev.configuration.semantic_snapshot_path
      path.dirname.mkpath
      path.write("previous-valid-artifact")
      allow(File).to receive(:rename).and_raise(Errno::EACCES)

      expect { invoke_semantic_task(:build) }.to raise_error(Errno::EACCES)
      expect(path.binread).to eq("previous-valid-artifact")
    end
  end
end
