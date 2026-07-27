# frozen_string_literal: true

require "rails_helper"
require "timeout"

class LifecycleEmbeddingAdapter
  def initialize(fail: false)
    @fail = fail
  end

  def maglev_adapter_id = "test.index_generation_lifecycle"
  def maglev_adapter_version = "1"

  def embed(_text)
    raise Maglev::PermanentProviderError, "failed" if @fail

    [1.0, 0.0, 0.0]
  end
end

class LifecycleChunk < ActiveRecord::Base
  self.table_name = "lifecycle_maglev_chunks"
  belongs_to :owner, polymorphic: true
  has_neighbors :embedding
end

class PausingPgvector < Maglev::VectorStores::Pgvector
  def pause_next_search(entered:, release:)
    @pause = [entered, release]
  end

  def search(...)
    if (pause = @pause)
      @pause = nil
      pause.first << true
      pause.last.pop
    end
    super
  end
end

RSpec.describe "PostgreSQL and pgvector index generation lifecycle" do
  around do |example|
    connection = ActiveRecord::Base.connection
    unless connection.adapter_name == "PostgreSQL" && connection.extension_enabled?("vector")
      skip "PostgreSQL with pgvector is not available; CI requires this integration test"
    end

    original = Maglev.configuration
    configuration = Maglev::Configuration.new
    configuration.embedding_dimensions = 3
    Maglev.instance_variable_set(:@configuration, configuration)
    connection.create_table(:lifecycle_maglev_chunks, force: true) do |t|
      t.string :owner_type, null: false
      t.bigint :owner_id, null: false
      t.string :owner_model_name, null: false
      t.string :resource_identifier, null: false
      t.string :representation_version, null: false
      t.string :knowledge_policy_digest, limit: 64, null: false
      t.string :generation
      t.string :source, null: false
      t.string :source_identity, null: false
      t.string :source_type, null: false
      t.string :tenant_id
      t.integer :chunk_index, null: false
      t.text :content, null: false
      t.jsonb :context, null: false, default: {}
      t.string :content_checksum, null: false
      t.string :embedding_model, null: false
      t.string :index_version, limit: 64, null: false
      t.vector :embedding, limit: 3, null: false
      t.timestamps
    end
    connection.add_index :lifecycle_maglev_chunks, :embedding, using: :hnsw, opclass: :vector_cosine_ops
    LifecycleChunk.reset_column_information
    Product.delete_all
    LifecycleChunk.delete_all
    Maglev::IndexGeneration.delete_all
    example.run
  ensure
    Product.delete_all if Product.table_exists?
    LifecycleChunk.delete_all if LifecycleChunk.table_exists?
    Maglev::IndexGeneration.delete_all if Maglev::IndexGeneration.table_exists?
    connection&.drop_table(:lifecycle_maglev_chunks, if_exists: true)
    Maglev.instance_variable_set(:@configuration, original) if original
  end

  it "rebuilds beside active data, survives failure, and atomically switches concurrent readers" do
    product_entry = Maglev::Registry.entries.find { |entry| entry.model_class == Product }
    allow(Maglev::Registry).to receive(:entries).and_return([product_entry])
    Product.create!(name: "old knowledge", sku: "LIFECYCLE", price: 10, status: "active")
    store = PausingPgvector.new(chunk_model: LifecycleChunk)
    adapter = LifecycleEmbeddingAdapter.new
    active = rebuild(store, adapter, "active")
    activate(active, adapter)
    Product.update_all(name: "new knowledge")

    expect do
      rebuild(store, LifecycleEmbeddingAdapter.new(fail: true), "failed")
    end.to raise_error(Maglev::PermanentProviderError)
    expect(Maglev::IndexGeneration.find_by!(generation: "failed").status).to eq("failed")
    expect(Maglev.active_index_generation).to eq(active.reload)

    candidate = rebuild(store, adapter, "candidate")
    expect(search_content(store, adapter)).to include("old knowledge")

    entered = Queue.new
    release = Queue.new
    store.pause_next_search(entered: entered, release: release)
    in_flight = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        search_content(store, adapter)
      end
    end
    Timeout.timeout(10) { entered.pop }
    activate(candidate, adapter)
    release << true
    old_content = Timeout.timeout(10) { in_flight.value }
    new_content = search_content(store, adapter)

    expect(classify(old_content)).to eq(:old)
    expect(classify(new_content)).to eq(:new)
    expect(Maglev::IndexGeneration.obsolete).to contain_exactly(active.reload)
  end

  def rebuild(store, adapter, generation)
    Maglev.rebuild_index!(
      resources: [Product],
      vector_store: store,
      embedding_adapter: adapter,
      embedding_dimensions: 3,
      generation: generation
    )
  end

  def activate(generation, adapter)
    Maglev.activate_index_generation!(
      generation.generation,
      embedding_adapter: adapter,
      embedding_dimensions: 3
    )
  end

  def search_content(store, adapter)
    Maglev::Retriever.new(
      Product,
      vector_store: store,
      embedding_adapter: adapter,
      embedding_dimensions: 3
    ).search("knowledge", limit: 10).map(&:content).join("\n")
  end

  def classify(content)
    old = content.include?("old knowledge")
    new = content.include?("new knowledge")
    return :mixed if old && new
    return :old if old
    return :new if new

    :missing
  end
end
