# frozen_string_literal: true

require "rails_helper"
require "timeout"
require "maglev/vector_stores/document"
require "maglev/vector_stores/pgvector"

class PgvectorStoreOwner < ActiveRecord::Base
  self.table_name = "pgvector_store_owners"
end

RSpec.describe "Pgvector vector store adapter" do
  around do |example|
    unless pgvector_available?
      skip "PostgreSQL with pgvector is not available; CI requires this integration test"
    end

    connection = ActiveRecord::Base.connection
    connection.create_table(:maglev_chunks, force: true) do |t|
      t.string :owner_type, null: false
      t.bigint :owner_id, null: false
      t.string :owner_model_name, null: false
      t.string :source, null: false
      t.string :source_identity, null: false
      t.string :source_type, null: false
      t.string :tenant_id
      t.integer :chunk_index, null: false
      t.text :content, null: false
      t.string :content_checksum, null: false
      t.string :embedding_model, null: false
      t.string :index_version, limit: 64, null: false
      t.vector :embedding, limit: 2, null: false
      t.timestamps
    end
    connection.create_table(:pgvector_store_owners, force: true) do |t|
      t.string :name
      t.timestamps
    end
    connection.add_index :maglev_chunks, :embedding, using: :hnsw, opclass: :vector_cosine_ops
    connection.clear_cache!
    Maglev::Chunk.reset_column_information
    example.run
  ensure
    connection&.drop_table(:maglev_chunks, if_exists: true)
    connection&.drop_table(:pgvector_store_owners, if_exists: true)
  end

  it "upserts, searches with metadata filters, and deletes documents" do
    owner = PgvectorStoreOwner.create!(name: "Acme")
    other_owner = PgvectorStoreOwner.create!(name: "Beta")
    store = Maglev::VectorStores::Pgvector.new
    store.upsert(documents: [
      document_for(owner, content: "risk", checksum: "a", embedding: [1.0, 0.0]),
      document_for(other_owner, content: "safe", checksum: "b", embedding: [0.0, 1.0])
    ])

    results = store.search(vector: [1.0, 0.0], filters: {owner_model_name: "PgvectorStoreOwner"}, limit: 2)
    filtered = store.search(vector: [1.0, 0.0], filters: {owner_model_name: "PgvectorStoreOwner", owner_id: other_owner.id}, limit: 2)

    expect(results.map(&:owner_id)).to eq([owner.id, other_owner.id])
    expect(results.first).to have_attributes(source_identity: "snapshot", source_type: :snapshot, score: 1.0)
    expect(filtered.map(&:owner_id)).to eq([other_owner.id])
    expect(store.healthcheck).to eq(:ok)
    expect(store.capabilities).to include(:metadata_filtering, :pgvector)
    expect(store.fetch(ids: [document_for(other_owner, content: "safe", checksum: "b", embedding: [0.0, 1.0]).id]).first.index_version).to eq("a" * 64)

    store.delete_by_owner(owner_type: "PgvectorStoreOwner", owner_id: owner.id)
    expect(store.search(vector: [1.0, 0.0], filters: {owner_model_name: "PgvectorStoreOwner"}, limit: 2).map(&:owner_id))
      .to eq([other_owner.id])
  end

  it "rolls back a failed owner replacement and removes obsolete rows after a successful replacement" do
    owner = PgvectorStoreOwner.create!(name: "Acme")
    store = Maglev::VectorStores::Pgvector.new
    old = [
      document_for(owner, chunk_index: 0, content: "old zero", checksum: "old-0", embedding: [1.0, 0.0]),
      document_for(owner, chunk_index: 1, content: "old one", checksum: "old-1", embedding: [1.0, 0.0])
    ]
    store.upsert(documents: old)
    invalid = [
      document_for(owner, chunk_index: 0, content: "new zero", checksum: "new-0", embedding: [0.0, 1.0]),
      document_for(owner, chunk_index: 1, content: "invalid", checksum: "bad", embedding: [1.0])
    ]

    expect do
      store.replace_owner(owner_type: "PgvectorStoreOwner", owner_id: owner.id, documents: invalid)
    end.to raise_error(ActiveRecord::RecordInvalid)
    expect(store.fetch(ids: old.map(&:id)).map(&:content)).to eq(["old zero", "old one"])

    replacement = [document_for(owner, chunk_index: 0, content: "final", checksum: "final", embedding: [0.0, 1.0])]
    store.replace_owner(owner_type: "PgvectorStoreOwner", owner_id: owner.id, documents: replacement)

    expect(store.fetch(ids: old.map(&:id)).map(&:content)).to eq(["final"])
  end

  it "linearizes concurrent replacements for the same owner" do
    owner = PgvectorStoreOwner.create!(name: "Acme")
    generations = %w[a b].map do |generation|
      2.times.map do |index|
        document_for(owner, chunk_index: index, content: "#{generation}-#{index}", checksum: "#{generation}-#{index}", embedding: [1.0, 0.0])
      end
    end
    errors = Queue.new

    threads = generations.map do |documents|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Maglev::VectorStores::Pgvector.new.replace_owner(owner_type: "PgvectorStoreOwner", owner_id: owner.id, documents: documents)
        end
      rescue => error
        errors << error
      end
    end
    threads.each { |thread| Timeout.timeout(5) { thread.join } }

    contents = Maglev::Chunk.where(owner_type: "PgvectorStoreOwner", owner_id: owner.id).order(:chunk_index).pluck(:content)
    expect(errors).to be_empty
    expect(contents).to satisfy { |values| values == %w[a-0 a-1] || values == %w[b-0 b-1] }
  end

  it "keeps the old generation visible while replacement is uncommitted after deletion" do
    owner = PgvectorStoreOwner.create!(name: "Acme")
    old = 2.times.map { |index| document_for(owner, chunk_index: index, content: "old-#{index}", checksum: "old-#{index}", embedding: [1.0, 0.0]) }
    replacement = 2.times.map { |index| document_for(owner, chunk_index: index, content: "new-#{index}", checksum: "new-#{index}", embedding: [0.0, 1.0]) }
    Maglev::VectorStores::Pgvector.new.upsert(documents: old)
    paused = Queue.new
    release = Queue.new
    errors = Queue.new
    paused_once = false
    chunk_model = Class.new(Maglev::Chunk)
    chunk_model.define_singleton_method(:create!) do |attributes|
      unless paused_once
        paused_once = true
        paused << true
        Timeout.timeout(5) { release.pop }
      end
      super(attributes)
    end
    replacing = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Maglev::VectorStores::Pgvector.new(chunk_model: chunk_model).replace_owner(owner_type: "PgvectorStoreOwner", owner_id: owner.id, documents: replacement)
      end
    rescue => error
      errors << error
    end
    wait_for_signal(paused, errors)

    visible = Maglev::Chunk.where(owner_type: "PgvectorStoreOwner", owner_id: owner.id).order(:chunk_index).pluck(:content)
    release << true
    Timeout.timeout(5) { replacing.join }

    expect(errors).to be_empty
    expect(visible).to eq(%w[old-0 old-1])
    expect(Maglev::Chunk.where(owner_type: "PgvectorStoreOwner", owner_id: owner.id).order(:chunk_index).pluck(:content)).to eq(%w[new-0 new-1])
  ensure
    release << true if replacing&.alive?
    Timeout.timeout(5) { replacing&.join }
  end

  it "linearizes replacement and deletion according to advisory lock acquisition order" do
    owner = PgvectorStoreOwner.create!(name: "Acme")
    replacement = 2.times.map { |index| document_for(owner, chunk_index: index, content: "new-#{index}", checksum: "new-#{index}", embedding: [1.0, 0.0]) }

    run_locked_owner_race(owner, first: :replace, replacement: replacement)
    expect(Maglev::Chunk.where(owner_type: "PgvectorStoreOwner", owner_id: owner.id)).to be_empty

    run_locked_owner_race(owner, first: :delete, replacement: replacement)
    expect(Maglev::Chunk.where(owner_type: "PgvectorStoreOwner", owner_id: owner.id).order(:chunk_index).pluck(:content)).to eq(%w[new-0 new-1])
  end

  it "uses the owner advisory lock when deleting" do
    owner = PgvectorStoreOwner.create!(name: "Acme")
    store = Maglev::VectorStores::Pgvector.new
    sql = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      sql << payload[:sql]
    end

    store.delete_by_owner(owner_type: "PgvectorStoreOwner", owner_id: owner.id)

    expect(sql.grep(/pg_advisory_xact_lock/).one?).to be(true)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it "fetches and deletes stable ids with namespaced owner types" do
    stub_const("Admin", Module.new)
    stub_const("Admin::Customer", Class.new(ActiveRecord::Base) do
      self.table_name = "pgvector_store_owners"
    end)
    Admin::Customer.create!(id: 42, name: "Namespaced")
    store = Maglev::VectorStores::Pgvector.new
    document = Maglev::VectorStores::Document.new(
      owner_type: "Admin::Customer",
      owner_id: 42,
      owner_model_name: "Admin::Customer",
      source: "snapshot",
      chunk_index: 0,
      content: "namespaced",
      content_checksum: "namespaced",
      embedding_model: "fake",
      index_version: "a" * 64,
      embedding: [1.0, 0.0]
    )
    Maglev::Chunk.create!(
      owner_type: document.owner_type,
      owner_id: document.owner_id,
      owner_model_name: document.owner_model_name,
      source: document.source,
      source_identity: document.source_identity,
      source_type: document.source_type,
      chunk_index: document.chunk_index,
      content: document.content,
      content_checksum: document.content_checksum,
      embedding_model: document.embedding_model,
      index_version: document.index_version,
      embedding: document.embedding
    )

    expect(store.fetch(ids: [document.id]).map(&:content)).to eq(["namespaced"])

    store.delete(ids: [document.id])
    expect(store.fetch(ids: [document.id])).to be_empty
  end

  def document_for(owner, content:, checksum:, embedding:, chunk_index: 0)
    Maglev::VectorStores::Document.new(
      owner_type: "PgvectorStoreOwner",
      owner_id: owner.id,
      owner_model_name: "PgvectorStoreOwner",
      owner: owner,
      source: "snapshot",
      chunk_index: chunk_index,
      content: content,
      content_checksum: checksum,
      embedding_model: "fake",
      index_version: "a" * 64,
      embedding: embedding
    )
  end

  def run_locked_owner_race(owner, first:, replacement:)
    acquired = Queue.new
    release = Queue.new
    errors = Queue.new
    locking_store = Class.new(Maglev::VectorStores::Pgvector) do
      define_method(:lock_owner) do |owner_type, owner_id|
        super(owner_type, owner_id)
        acquired << true
        Timeout.timeout(5) { release.pop }
      end
    end.new
    normal_store = Maglev::VectorStores::Pgvector.new
    operations = {
      replace: ->(store) { store.replace_owner(owner_type: "PgvectorStoreOwner", owner_id: owner.id, documents: replacement) },
      delete: ->(store) { store.delete_by_owner(owner_type: "PgvectorStoreOwner", owner_id: owner.id) }
    }
    second = (first == :replace) ? :delete : :replace
    first_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { operations.fetch(first).call(locking_store) }
    rescue => error
      errors << error
    end
    wait_for_signal(acquired, errors)
    second_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { operations.fetch(second).call(normal_store) }
    rescue => error
      errors << error
    end
    release << true
    Timeout.timeout(5) { first_thread.join }
    Timeout.timeout(5) { second_thread.join }
    expect(errors).to be_empty
  ensure
    release << true if first_thread&.alive?
    Timeout.timeout(5) { first_thread&.join }
    Timeout.timeout(5) { second_thread&.join }
  end

  def wait_for_signal(queue, errors)
    Timeout.timeout(5) { queue.pop }
  rescue Timeout::Error
    raise errors.pop unless errors.empty?

    raise
  end

  def pgvector_available?
    connection = ActiveRecord::Base.connection
    connection.enable_extension("vector")
    connection.extension_enabled?("vector")
  rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::StatementInvalid, PG::Error
    raise if ENV["MAGLEV_REQUIRE_POSTGRESQL"] == "true"

    false
  end
end
