# frozen_string_literal: true

RSpec.shared_examples "a Maglev vector store" do
  it "implements contract v2 with validated filters and normalized scores" do
    store = described_class.new
    document = document_for_compliance(owner_id: 1, chunk_index: 0, content: "exact")
    store.upsert(documents: [document])

    filters = Maglev::VectorStores::MetadataFilter.new(
      owner_model_name: "Customer",
      owner_ids: [1],
      source_types: [:attribute],
      index_version: "a" * 64
    )
    result = store.search(vector: [1.0, 0.0], filters: filters, limit: 1).first

    expect(store.contract_version).to eq(2)
    expect(result.score).to eq(1.0)
    expect(result.source_identity).to eq("attribute:name")
    expect { Maglev::VectorStores::MetadataFilter.new(secret: "escape") }
      .to raise_error(ArgumentError, /Unsupported metadata filter/)
    expect { Maglev::VectorStores::MetadataFilter.new(owner_ids: []) }
      .to raise_error(ArgumentError, /non-empty Array/)
    expect { Maglev::VectorStores::MetadataFilter.new(source_types: [:unknown]) }
      .to raise_error(ArgumentError, /Unsupported source type/)
  end

  it "upserts, searches with metadata filters, deletes documents, and reports health" do
    store = described_class.new
    documents = [
      Maglev::VectorStores::Document.new(
        id: "Customer:1:snapshot:0",
        owner_type: "Customer",
        owner_id: 1,
        owner_model_name: "Customer",
        source: "snapshot",
        chunk_index: 0,
        content: "risk",
        content_checksum: "a",
        embedding_model: "fake",
        index_version: "a" * 64,
        embedding: [1.0, 0.0]
      ),
      Maglev::VectorStores::Document.new(
        id: "Customer:2:snapshot:0",
        owner_type: "Customer",
        owner_id: 2,
        owner_model_name: "Customer",
        source: "snapshot",
        chunk_index: 0,
        content: "safe",
        content_checksum: "b",
        embedding_model: "fake",
        index_version: "a" * 64,
        embedding: [0.0, 1.0]
      )
    ]

    store.upsert(documents: documents)

    results = store.search(vector: [1.0, 0.0], filters: {owner_model_name: "Customer"}, limit: 2)
    filtered = store.search(vector: [1.0, 0.0], filters: {owner_model_name: "Customer", owner_id: 2}, limit: 2)

    expect(results.map(&:id)).to eq(["Customer:1:snapshot:0", "Customer:2:snapshot:0"])
    expect(filtered.map(&:id)).to eq(["Customer:2:snapshot:0"])
    expect(store.healthcheck).to eq(:ok)
    expect(store.capabilities).to include(:metadata_filtering)
    expect(store.fetch(ids: [documents.last.id, documents.first.id])).to eq(documents.reverse)
    expect(results.first.metadata).to include(index_version: "a" * 64)

    store.delete(ids: ["Customer:1:snapshot:0"])
    expect(store.search(vector: [1.0, 0.0], filters: {owner_model_name: "Customer"}, limit: 2).map(&:id))
      .to eq(["Customer:2:snapshot:0"])

    store.delete_by_owner(owner_type: "Customer", owner_id: 2)
    expect(store.search(vector: [1.0, 0.0], filters: {owner_model_name: "Customer"}, limit: 2)).to eq([])
  end

  it "atomically replaces an owner's complete document set" do
    store = described_class.new
    old_documents = [
      document_for_compliance(owner_id: 1, chunk_index: 0, content: "old zero"),
      document_for_compliance(owner_id: 1, chunk_index: 1, content: "obsolete")
    ]
    replacement = [document_for_compliance(owner_id: 1, chunk_index: 0, content: "new zero")]
    store.upsert(documents: old_documents)

    store.replace_owner(owner_type: "Customer", owner_id: 1, documents: replacement)

    expect(store.fetch(ids: old_documents.map(&:id))).to eq(replacement)
  end

  it "isolates index versions and preserves the old generation on invalid replacement" do
    store = described_class.new
    current = document_for_compliance(owner_id: 1, chunk_index: 0, content: "current")
    legacy = Maglev::VectorStores::Document.new(**document_attributes_for_compliance(owner_id: 2, chunk_index: 0, content: "legacy"),
      index_version: "b" * 64)
    store.upsert(documents: [current, legacy])

    results = store.search(vector: [1.0, 0.0], filters: {owner_model_name: "Customer", index_version: "a" * 64}, limit: 10)
    expect(results.map(&:content)).to eq(["current"])

    expect do
      store.replace_owner(owner_type: "Customer", owner_id: 1,
        documents: [document_for_compliance(owner_id: 2, chunk_index: 0, content: "wrong")])
    end.to raise_error(ArgumentError, /owner/)
    expect(store.fetch(ids: [current.id])).to eq([current])
  end

  def document_for_compliance(owner_id:, chunk_index:, content:)
    Maglev::VectorStores::Document.new(**document_attributes_for_compliance(owner_id: owner_id, chunk_index: chunk_index, content: content),
      index_version: "a" * 64)
  end

  def document_attributes_for_compliance(owner_id:, chunk_index:, content:)
    {
      owner_type: "Customer",
      owner_id: owner_id,
      owner_model_name: "Customer",
      source: "snapshot",
      source_identity: "attribute:name",
      source_type: :attribute,
      chunk_index: chunk_index,
      content: content,
      content_checksum: content,
      embedding_model: "fake",
      embedding: [1.0, 0.0]
    }
  end
end
