# frozen_string_literal: true

require "rails_helper"
require "active_job/test_helper"
require "maglev/reindex_job"
require "maglev/indexer"
require "maglev/errors"

class ReindexTestOwner
  def self.name
    "ReindexTestOwner"
  end

  attr_reader :id

  def initialize(id)
    @id = id
  end

  def self.find(id)
    raise ActiveRecord::RecordNotFound unless id

    new(id)
  end
end

class ReindexFakeEmbeddingAdapter
  def embed(text)
    [0.1, 0.2, 0.3]
  end
end

class ReindexFakeChunkModel
  def self.columns_hash
    {"embedding" => OpenStruct.new(limit: 3)}
  end

  def self.where(conditions)
    self
  end

  def self.find_by(**args)
    nil
  end
end

RSpec.describe Maglev::ReindexJob do
  include ActiveJob::TestHelper

  around do |example|
    original = Maglev.configuration
    configuration = Maglev::Configuration.new
    configuration.embedding_dimensions = 3
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    Maglev.instance_variable_set(:@configuration, configuration)
    example.run
  ensure
    Maglev.instance_variable_set(:@configuration, original)
  end

  describe "retry behavior" do
    it "enqueues a bounded retry for RetryableProviderError" do
      Maglev.configuration.provider_max_attempts = 2
      allow_any_instance_of(Maglev::Indexer).to receive(:index).and_raise(Maglev::RetryableProviderError, "timeout")

      expect { described_class.perform_now("ReindexTestOwner", 1) }
        .to change { enqueued_jobs.size }.by(1)

      expect(enqueued_jobs.last[:job]).to eq(described_class)
    end

    it "does not retry PermanentProviderError" do
      attempts = 0
      allow_any_instance_of(Maglev::Indexer).to receive(:index) do
        attempts += 1
        raise Maglev::PermanentProviderError, "bad request"
      end

      expect { described_class.perform_now("ReindexTestOwner", 1) }.not_to raise_error
      expect(attempts).to eq(1)
    end

    it "does not retry stale RecordNotFound" do
      allow(ReindexTestOwner).to receive(:find).and_raise(ActiveRecord::RecordNotFound)

      expect { described_class.perform_now("ReindexTestOwner", 999) }.not_to raise_error
    end

    it "executes one provider call per job attempt and succeeds within the total budget" do
      Maglev.configuration.provider_max_attempts = 3
      attempts = 0
      allow(Maglev::Indexer).to receive(:new) do |_owner, provider_call:|
        Object.new.tap do |indexer|
          indexer.define_singleton_method(:index) do
            provider_call.call(operation: "embed") do
              attempts += 1
              raise Maglev::RetryableProviderError, "timeout" if attempts < 3
            end
          end
        end
      end

      perform_enqueued_jobs do
        described_class.perform_later("ReindexTestOwner", 1)
      end

      expect(attempts).to eq(3)
      expect(enqueued_jobs).to be_empty
    end

    it "exhausts after exactly the configured total job executions" do
      Maglev.configuration.provider_max_attempts = 3
      attempts = 0
      allow_any_instance_of(Maglev::Indexer).to receive(:index) do
        attempts += 1
        raise Maglev::RetryableProviderError, "timeout"
      end

      error = nil
      perform_enqueued_jobs do
        described_class.perform_later("ReindexTestOwner", 1)
      rescue Maglev::RetryableProviderError => caught
        error = caught
      end

      expect(error).to be_a(Maglev::RetryableProviderError)
      expect(attempts).to eq(3)
      expect(enqueued_jobs).to be_empty
    end
  end

  describe "notifications" do
    it "emits maglev.reindex.retry on retryable failure" do
      Maglev.configuration.provider_max_attempts = 2
      events = []
      subscription = ActiveSupport::Notifications.subscribe("maglev.reindex.retry") do |_name, _start, _finish, _id, payload|
        events << payload
      end

      allow_any_instance_of(Maglev::Indexer).to receive(:index)
        .and_raise(Maglev::RetryableProviderError, "timeout")

      described_class.perform_now("ReindexTestOwner", 1)

      expect(events).not_to be_empty
      expect(events.first).to include(owner_class: "ReindexTestOwner", owner_id: 1)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription) if subscription
    end

    it "emits maglev.reindex.discard on permanent failure" do
      events = []
      subscription = ActiveSupport::Notifications.subscribe("maglev.reindex.discard") do |_name, _start, _finish, _id, payload|
        events << payload
      end

      allow_any_instance_of(Maglev::Indexer).to receive(:index)
        .and_raise(Maglev::PermanentProviderError, "bad request")

      described_class.perform_now("ReindexTestOwner", 1)

      expect(events).not_to be_empty
      expect(events.first).to include(owner_class: "ReindexTestOwner", owner_id: 1)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription) if subscription
    end

    it "emits exhaustion without enqueueing another retry" do
      Maglev.configuration.provider_max_attempts = 1
      events = []
      subscription = ActiveSupport::Notifications.subscribe("maglev.reindex.exhausted") do |_name, _start, _finish, _id, payload|
        events << payload
      end
      allow_any_instance_of(Maglev::Indexer).to receive(:index).and_raise(Maglev::RetryableProviderError, "timeout")

      expect { described_class.perform_now("ReindexTestOwner", 1) }.to raise_error(Maglev::RetryableProviderError)

      expect(enqueued_jobs).to be_empty
      expect(events.first).to include(job_class: "Maglev::ReindexJob", execution_count: 1, attempt: 1, max_attempts: 1)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription) if subscription
    end
  end
end
