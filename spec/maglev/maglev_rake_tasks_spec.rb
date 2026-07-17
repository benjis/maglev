# frozen_string_literal: true

require "spec_helper"
require "rake"
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

  has_knowledge do
    expose :name
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
    first_version = store.fetch(ids: ["TaskRecord:1:snapshot:0"]).first.index_version
    expect(adapter.calls).to eq(2)

    Rake::Task["maglev:reindex"].reenable
    Rake::Task["maglev:reindex"].invoke("TaskRecord")
    expect(adapter.calls).to eq(2)

    configuration.application_index_version = "2"
    Rake::Task["maglev:reindex"].reenable
    Rake::Task["maglev:reindex"].invoke("TaskRecord")

    expect(adapter.calls).to eq(4)
    expect(store.fetch(ids: ["TaskRecord:1:snapshot:0"]).first.index_version).not_to eq(first_version)
  ensure
    Maglev.instance_variable_set(:@configuration, original)
  end

  it "prints configured model status" do
    allow(ActiveRecord::Base).to receive(:descendants).and_return([TaskRecord])

    expect do
      Rake::Task["maglev:status"].invoke
    end.to output(/TaskRecord/).to_stdout
  end
end
