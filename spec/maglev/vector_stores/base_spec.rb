# frozen_string_literal: true

require "spec_helper"
require "maglev/vector_stores/base"

RSpec.describe Maglev::VectorStores::Base do
  it "defines the vector store adapter contract" do
    store = described_class.new

    expect { store.fetch(ids: []) }.to raise_error(NotImplementedError)
    expect { store.upsert(documents: []) }.to raise_error(NotImplementedError)
    expect do
      store.replace_owner(owner_type: "Customer", owner_id: 1, documents: [])
    end.to raise_error(NotImplementedError)
    expect { store.search(vector: [], filters: {}, limit: 1) }.to raise_error(NotImplementedError)
    expect { store.delete(ids: []) }.to raise_error(NotImplementedError)
    expect { store.delete_by_owner(owner_type: "Customer", owner_id: 1) }.to raise_error(NotImplementedError)
    expect { store.healthcheck }.to raise_error(NotImplementedError)
    expect(store.capabilities).to eq({})
  end
end
