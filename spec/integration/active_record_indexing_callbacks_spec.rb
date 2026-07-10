# frozen_string_literal: true

require "rails_helper"

RSpec.describe "ActiveRecord indexing callbacks" do
  before do
    stub_const("SearchableCustomer", Class.new(ActiveRecord::Base) do
      def self.attribute_names
        %w[id name description]
      end
    end)
  end

  it "registers after-commit indexing callbacks once for configured models" do
    callback_count_before = SearchableCustomer._commit_callbacks.count

    2.times do
      SearchableCustomer.has_knowledge do
        expose :name, :description
      end
    end

    callback_count_after = SearchableCustomer._commit_callbacks.count

    expect(callback_count_after - callback_count_before).to eq(2)
  end

  it "exposes search as a configured class API" do
    SearchableCustomer.has_knowledge do
      expose :name
    end

    allow(Maglev::Retriever).to receive(:new).and_return(instance_double(Maglev::Retriever, search: ["result"]))

    expect(SearchableCustomer.search("support", limit: 3)).to eq(["result"])
    expect(Maglev::Retriever).to have_received(:new).with(SearchableCustomer)
  end

  it "enqueues reindexing through the configured callback method" do
    SearchableCustomer.has_knowledge do
      expose :name
    end
    customer = SearchableCustomer.allocate
    allow(customer).to receive(:id).and_return(42)
    allow(Maglev::ReindexJob).to receive(:perform_later)

    customer.send(:maglev_reindex)

    expect(Maglev::ReindexJob).to have_received(:perform_later).with("SearchableCustomer", 42)
  end

  it "removes chunks through the configured destroy callback method" do
    SearchableCustomer.has_knowledge do
      expose :name
    end
    customer = SearchableCustomer.allocate
    indexer = instance_double(Maglev::Indexer, unindex: true)
    allow(Maglev::Indexer).to receive(:new).with(customer).and_return(indexer)

    customer.send(:maglev_unindex)

    expect(indexer).to have_received(:unindex)
  end

  it "exposes answer-generation APIs in phase 3" do
    SearchableCustomer.has_knowledge do
      expose :name
    end

    expect(SearchableCustomer).to respond_to(:ask)
    expect(SearchableCustomer.instance_methods).to include(:ask)
    expect(SearchableCustomer.instance_methods).to include(:explain)
  end
end
