# frozen_string_literal: true

require "rails_helper"
require "timeout"

class ConcurrentReindexBarrierAdapter
  attr_reader :transaction_states

  def maglev_adapter_id = "test.concurrent_reindex"

  def maglev_adapter_version = "1"

  def initialize(parties: nil, block_on: nil)
    @parties = parties
    @block_on = block_on
    @mutex = Mutex.new
    @condition = ConditionVariable.new
    @arrivals = 0
    @started = Queue.new
    @release = Queue.new
    @transaction_states = Queue.new
  end

  def embed(text)
    @transaction_states << ActiveRecord::Base.connection.transaction_open?
    wait_for_parties if @parties
    if @block_on && text.include?(@block_on)
      @started << true
      @release.pop
    end
    [1.0, 0.0, 0.0]
  end

  def wait_until_started
    Timeout.timeout(5) { @started.pop }
  end

  def release
    @release << true
  end

  private

  def wait_for_parties
    @mutex.synchronize do
      @arrivals += 1
      @condition.broadcast if @arrivals >= @parties
      @condition.wait(@mutex) while @arrivals < @parties
    end
  end
end

RSpec.describe "Concurrent reindexing" do
  before(:context) do
    connection = ActiveRecord::Base.connection
    connection.enable_extension("vector")
    connection.create_table(:concurrent_index_records, force: true) do |t|
      t.string :body, null: false
      t.timestamps
    end
    connection.create_table(:maglev_chunks, force: true) do |t|
      t.string :owner_type, null: false
      t.bigint :owner_id, null: false
      t.string :owner_model_name, null: false
      t.string :source, null: false
      t.integer :chunk_index, null: false
      t.text :content, null: false
      t.string :content_checksum, null: false
      t.string :embedding_model, null: false
      t.string :index_version, limit: 64, null: false
      t.vector :embedding, limit: 3, null: false
      t.timestamps
    end
    connection.add_index(
      :maglev_chunks,
      %i[owner_type owner_id source chunk_index],
      unique: true,
      name: "index_maglev_chunks_on_owner_source_chunk"
    )
    Maglev::Chunk.reset_column_information
    Object.const_set(:ConcurrentIndexRecord, Class.new(ActiveRecord::Base) do
      self.table_name = "concurrent_index_records"

      def maglev_snapshot = body
    end)
  end

  after(:context) do
    Object.send(:remove_const, :ConcurrentIndexRecord)
    connection = ActiveRecord::Base.connection
    connection.drop_table(:maglev_chunks, if_exists: true)
    connection.drop_table(:concurrent_index_records, if_exists: true)
    Maglev::Chunk.reset_column_information
  end

  it "serializes simultaneous writes for the same owner" do
    record = ConcurrentIndexRecord.create!(body: "same snapshot")
    adapter = ConcurrentReindexBarrierAdapter.new(parties: 2)
    errors = Queue.new

    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Maglev::Indexer.new(
            ConcurrentIndexRecord.find(record.id),
            embedding_adapter: adapter,
            embedding_dimensions: 3
          ).index
        end
      rescue => error
        errors << error
      end
    end
    threads.each { |thread| Timeout.timeout(5) { thread.join } }

    expect(errors.size).to eq(0)
    expect(Maglev::Chunk.where(owner: record).pluck(:content)).to eq(["same snapshot"])
  end

  it "does not hold a database transaction while embedding" do
    record = ConcurrentIndexRecord.create!(body: "snapshot")
    adapter = ConcurrentReindexBarrierAdapter.new

    Maglev::Indexer.new(record, embedding_adapter: adapter, embedding_dimensions: 3).index

    expect(adapter.transaction_states.pop).to be(false)
  end

  it "rejects a configured dimension that differs from the pgvector column" do
    record = ConcurrentIndexRecord.create!(body: "snapshot")
    adapter = ConcurrentReindexBarrierAdapter.new

    expect do
      Maglev::Indexer.new(record, embedding_adapter: adapter, embedding_dimensions: 2).index
    end.to raise_error(
      Maglev::ConfigurationError,
      /Configured embedding dimensions 2 do not match maglev_chunks\.embedding vector\(3\)/
    )

    expect(adapter.transaction_states).to be_empty
  end

  it "does not let a slower stale index overwrite newer record state" do
    record = ConcurrentIndexRecord.create!(body: "old snapshot")
    slow_adapter = ConcurrentReindexBarrierAdapter.new(block_on: "old snapshot")
    fast_adapter = ConcurrentReindexBarrierAdapter.new
    errors = Queue.new
    slow_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Maglev::Indexer.new(
          ConcurrentIndexRecord.find(record.id),
          embedding_adapter: slow_adapter,
          embedding_dimensions: 3
        ).index
      end
    rescue => error
      errors << error
    end

    slow_adapter.wait_until_started
    record.update!(body: "new snapshot")
    Maglev::Indexer.new(
      ConcurrentIndexRecord.find(record.id),
      embedding_adapter: fast_adapter,
      embedding_dimensions: 3
    ).index
    slow_adapter.release
    Timeout.timeout(5) { slow_thread.join }

    expect(errors.size).to eq(0)
    expect(Maglev::Chunk.where(owner: record).pluck(:content)).to eq(["new snapshot"])
  end
end
