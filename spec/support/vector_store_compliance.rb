# frozen_string_literal: true

RSpec.shared_examples "a Maglev vector store" do
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

    store.delete(ids: ["Customer:1:snapshot:0"])
    expect(store.search(vector: [1.0, 0.0], filters: {owner_model_name: "Customer"}, limit: 2).map(&:id))
      .to eq(["Customer:2:snapshot:0"])

    store.delete_by_owner(owner_type: "Customer", owner_id: 2)
    expect(store.search(vector: [1.0, 0.0], filters: {owner_model_name: "Customer"}, limit: 2)).to eq([])
  end
end
