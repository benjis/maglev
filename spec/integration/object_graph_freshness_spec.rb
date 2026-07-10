# frozen_string_literal: true

require "rails_helper"
require "active_job/test_helper"

class GraphStaticEmbeddingAdapter
  def embed(_text)
    [1.0, 0.0, 0.0]
  end
end

class GraphStaticGenerationAdapter
  def generate(prompt)
    "Grounded answer: #{prompt.include?("Escalated churn risk")}"
  end
end

RSpec.describe "Object graph knowledge freshness" do
  include ActiveJob::TestHelper

  around do |example|
    connection = ActiveRecord::Base.connection
    connection.create_table(:graph_customers, force: true) do |t|
      t.string :name
      t.timestamps
    end
    connection.create_table(:graph_tickets, force: true) do |t|
      t.string :subject
      t.references :graph_customer
      t.timestamps
    end
    connection.create_table(:graph_notes, force: true) do |t|
      t.string :body
      t.references :graph_customer
      t.timestamps
    end
    connection.enable_extension("vector")
    connection.create_table(:maglev_chunks, force: true) do |t|
      t.string :owner_type, null: false
      t.bigint :owner_id, null: false
      t.string :owner_model_name, null: false
      t.string :source, null: false
      t.integer :chunk_index, null: false
      t.text :content, null: false
      t.string :content_checksum, null: false
      t.string :embedding_model, null: false
      t.vector :embedding, limit: 3, null: false
      t.timestamps
    end
    example.run
  ensure
    clear_enqueued_jobs
    clear_performed_jobs
    connection&.drop_table(:graph_notes, if_exists: true)
    connection&.drop_table(:graph_tickets, if_exists: true)
    connection&.drop_table(:graph_customers, if_exists: true)
    connection&.drop_table(:maglev_chunks, if_exists: true)
  end

  before do
    ActiveJob::Base.queue_adapter = :test
    @original_embedding_adapter = Maglev.configuration.embedding_adapter
    @original_embedding_dimensions = Maglev.configuration.embedding_dimensions
    @original_generation_adapter = Maglev.configuration.generation_adapter
    Maglev.configuration.embedding_adapter = GraphStaticEmbeddingAdapter.new
    Maglev.configuration.embedding_dimensions = 3
    Maglev.configuration.generation_adapter = GraphStaticGenerationAdapter.new
    stub_const("GraphFreshnessTicket", Class.new(ActiveRecord::Base) do
      self.table_name = "graph_tickets"
      belongs_to :customer, class_name: "GraphFreshnessCustomer", inverse_of: :tickets, foreign_key: :graph_customer_id
    end)
    stub_const("GraphFreshnessNote", Class.new(ActiveRecord::Base) do
      self.table_name = "graph_notes"
      belongs_to :customer, class_name: "GraphFreshnessCustomer", inverse_of: :notes, foreign_key: :graph_customer_id
    end)
    stub_const("GraphFreshnessCustomer", Class.new(ActiveRecord::Base) do
      self.table_name = "graph_customers"
      has_many :tickets, class_name: "GraphFreshnessTicket", inverse_of: :customer, foreign_key: :graph_customer_id
      has_many :notes, class_name: "GraphFreshnessNote", inverse_of: :customer, foreign_key: :graph_customer_id
    end)

    GraphFreshnessTicket.has_knowledge do
      expose :subject
    end
    GraphFreshnessNote.has_knowledge do
      expose :body
    end
    GraphFreshnessCustomer.has_knowledge do
      expose :name
      include_related :tickets, depth: 1, limit: 2
    end
  end

  after do
    Maglev.configuration.embedding_adapter = @original_embedding_adapter
    Maglev.configuration.embedding_dimensions = @original_embedding_dimensions
    Maglev.configuration.generation_adapter = @original_generation_adapter
  end

  it "reindexes declared owners when related records are created, updated, or destroyed" do
    customer = GraphFreshnessCustomer.create!(name: "Acme")

    expect do
      GraphFreshnessTicket.create!(customer: customer, subject: "Initial risk")
    end.to have_enqueued_job(Maglev::ReindexJob).with("GraphFreshnessCustomer", customer.id)

    ticket = GraphFreshnessTicket.last
    clear_enqueued_jobs

    expect do
      ticket.update!(subject: "Escalated risk")
    end.to have_enqueued_job(Maglev::ReindexJob).with("GraphFreshnessCustomer", customer.id)

    clear_enqueued_jobs

    expect do
      ticket.destroy!
    end.to have_enqueued_job(Maglev::ReindexJob).with("GraphFreshnessCustomer", customer.id)
  end

  it "does not reindex owners for undeclared associations" do
    customer = GraphFreshnessCustomer.create!(name: "Acme")

    expect do
      GraphFreshnessNote.create!(customer: customer, body: "Private note")
    end.not_to have_enqueued_job(Maglev::ReindexJob).with("GraphFreshnessCustomer", customer.id)
  end

  it "does not register duplicate reverse callbacks across repeated declarations" do
    callback_count = GraphFreshnessTicket._commit_callbacks.count { |callback| callback.filter == :maglev_reindex_dependents }

    2.times do
      GraphFreshnessCustomer.has_knowledge do
        expose :name
        include_related :tickets, depth: 1, limit: 2
      end
    end

    expect(GraphFreshnessTicket._commit_callbacks.count { |callback| callback.filter == :maglev_reindex_dependents }).to eq(callback_count)
  end

  it "makes parent search and ask reflect related-record changes after jobs run" do
    customer = GraphFreshnessCustomer.create!(name: "Acme")
    ticket = GraphFreshnessTicket.create!(customer: customer, subject: "Initial support issue")
    clear_enqueued_jobs

    ticket.update!(subject: "Escalated churn risk")
    perform_enqueued_jobs

    search_result = GraphFreshnessCustomer.search("risk", limit: 1).first
    answer = GraphFreshnessCustomer.ask("Which customer is at risk?", limit: 1)
    instance_answer = customer.ask("Why is this customer at risk?", limit: 1)

    expect(search_result.content).to include("tickets[0].subject: Escalated churn risk")
    expect(answer.sources.first[:content]).to include("tickets[0].subject: Escalated churn risk")
    expect(instance_answer.sources.first[:content]).to include("tickets[0].subject: Escalated churn risk")
  end
end
