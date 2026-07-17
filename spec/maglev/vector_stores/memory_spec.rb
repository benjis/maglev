# frozen_string_literal: true

require "spec_helper"
require "delegate"
require "timeout"
require "support/vector_store_compliance"
require "maglev/vector_stores/document"
require "maglev/vector_stores/memory"

RSpec.describe Maglev::VectorStores::Memory do
  it_behaves_like "a Maglev vector store"

  it "rejects mixed-owner replacement before changing the current generation" do
    store = described_class.new
    old_documents = [document(owner_id: 1, chunk_index: 0, content: "old")]
    store.upsert(documents: old_documents)

    expect do
      store.replace_owner(
        owner_type: "Customer",
        owner_id: 1,
        documents: [document(owner_id: 1, chunk_index: 0, content: "new"), document(owner_id: 2, chunk_index: 1, content: "wrong")]
      )
    end.to raise_error(ArgumentError, /owner/)

    expect(store.fetch(ids: old_documents.map(&:id))).to eq(old_documents)
  end

  it "preserves the current generation when staging replacement raises" do
    store = described_class.new
    old_documents = [document(owner_id: 1, chunk_index: 0, content: "old")]
    store.upsert(documents: old_documents)
    failing_documents = Enumerator.new do |items|
      items << document(owner_id: 1, chunk_index: 0, content: "new")
      raise "staging failed"
    end

    expect do
      store.replace_owner(owner_type: "Customer", owner_id: 1, documents: failing_documents)
    end.to raise_error("staging failed")

    expect(store.fetch(ids: old_documents.map(&:id))).to eq(old_documents)
  end

  it "reads document ids before locking and preserves the current generation when an id getter raises" do
    store = described_class.new
    old_documents = [document(owner_id: 1, chunk_index: 0, content: "old")]
    store.upsert(documents: old_documents)
    invalid = Class.new(SimpleDelegator) do
      def id = raise "id failed"
    end.new(document(owner_id: 1, chunk_index: 0, content: "new"))

    expect do
      store.replace_owner(owner_type: "Customer", owner_id: 1, documents: [invalid])
    end.to raise_error("id failed")

    expect(store.fetch(ids: old_documents.map(&:id))).to eq(old_documents)
  end

  it "does not hold the mutex while reading a replacement document id" do
    store = described_class.new
    old_documents = [document(owner_id: 1, chunk_index: 0, content: "old")]
    store.upsert(documents: old_documents)
    started = Queue.new
    release = Queue.new
    errors = Queue.new
    replacement = Class.new(SimpleDelegator) do
      define_method(:id) do
        started << true
        Timeout.timeout(5) { release.pop }
        "Customer:1:snapshot:0"
      end
    end.new(document(owner_id: 1, chunk_index: 0, content: "new"))

    replacing = Thread.new do
      store.replace_owner(owner_type: "Customer", owner_id: 1, documents: [replacement])
    rescue => error
      errors << error
    end
    wait_for_signal(started, errors)

    expect(store.search(vector: [1.0, 0.0], filters: {owner_id: 1}, limit: 1).map(&:content)).to eq(["old"])
  ensure
    release << true if replacing&.alive?
    Timeout.timeout(5) { replacing&.join }
    raise errors.pop if errors && !errors.empty?
  end

  it "rejects an explicit document id already owned by another owner without changing state" do
    store = described_class.new
    existing = document(owner_id: 2, chunk_index: 0, content: "other", id: "shared-id")
    old_documents = [document(owner_id: 1, chunk_index: 0, content: "old")]
    store.upsert(documents: [existing, *old_documents])
    conflicting = document(owner_id: 1, chunk_index: 0, content: "new", id: "shared-id")

    expect do
      store.replace_owner(owner_type: "Customer", owner_id: 1, documents: [conflicting])
    end.to raise_error(ArgumentError, /document id/)

    expect(store.fetch(ids: [existing.id, *old_documents.map(&:id)])).to eq([existing, *old_documents])
  end

  it "materializes fetch ids without holding the mutex" do
    store = described_class.new
    stored = document(owner_id: 1, chunk_index: 0, content: "stored")
    store.upsert(documents: [stored])
    ids = Enumerator.new do |items|
      store.search(vector: [1.0, 0.0], filters: {owner_id: 1}, limit: 1)
      items << stored.id
    end

    expect(store.fetch(ids: ids)).to eq([stored])
  end

  it "materializes delete ids without holding the mutex" do
    store = described_class.new
    stored = document(owner_id: 1, chunk_index: 0, content: "stored")
    store.upsert(documents: [stored])
    ids = Enumerator.new do |items|
      store.search(vector: [1.0, 0.0], filters: {owner_id: 1}, limit: 1)
      items << stored.id
    end

    store.delete(ids: ids)

    expect(store.fetch(ids: [stored.id])).to be_empty
  end

  it "keeps searches on a complete generation while a replacement is being staged" do
    store = described_class.new
    old_documents = [document(owner_id: 1, chunk_index: 0, content: "old zero"), document(owner_id: 1, chunk_index: 1, content: "old one")]
    new_documents = [document(owner_id: 1, chunk_index: 0, content: "new zero"), document(owner_id: 1, chunk_index: 1, content: "new one")]
    store.upsert(documents: old_documents)
    staged = Queue.new
    release = Queue.new
    errors = Queue.new
    replacement = Enumerator.new do |items|
      items << new_documents.first
      staged << true
      Timeout.timeout(5) { release.pop }
      items << new_documents.last
    end

    replacing = Thread.new do
      store.replace_owner(owner_type: "Customer", owner_id: 1, documents: replacement)
    rescue => error
      errors << error
    end
    wait_for_signal(staged, errors)

    during = store.search(vector: [1.0, 0.0], filters: {owner_id: 1}, limit: 2).map(&:content)
    release << true
    Timeout.timeout(5) { replacing.join }
    raise errors.pop unless errors.empty?
    after = store.search(vector: [1.0, 0.0], filters: {owner_id: 1}, limit: 2).map(&:content)

    expect(during).to contain_exactly("old zero", "old one")
    expect(after).to contain_exactly("new zero", "new one")
  ensure
    release << true if replacing&.alive?
    Timeout.timeout(5) { replacing&.join }
    raise errors.pop if errors && !errors.empty?
  end

  def wait_for_signal(queue, errors)
    Timeout.timeout(5) { queue.pop }
  rescue Timeout::Error
    raise errors.pop unless errors.empty?

    raise
  end

  def document(owner_id:, chunk_index:, content:, id: nil)
    Maglev::VectorStores::Document.new(
      owner_type: "Customer",
      owner_id: owner_id,
      owner_model_name: "Customer",
      source: "snapshot",
      chunk_index: chunk_index,
      content: content,
      content_checksum: content,
      embedding_model: "fake",
      index_version: "a" * 64,
      embedding: [1.0, 0.0],
      id: id
    )
  end
end
