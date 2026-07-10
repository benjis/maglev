# frozen_string_literal: true

require "rails_helper"
require "active_job/test_helper"
require "stringio"

class ContentEmbeddingAdapter
  def embed(_text)
    [1.0, 0.0, 0.0]
  end
end

class ContentGenerationAdapter
  def generate(prompt)
    "Attachment cited: #{prompt.include?("contracts[blob:") && prompt.include?("rich_text.notes.text")}"
  end
end

RSpec.describe "ActiveStorage and ActionText knowledge" do
  include ActiveJob::TestHelper

  around do |example|
    connection = ActiveRecord::Base.connection
    connection.enable_extension("vector")
    connection.create_table(:content_customers, force: true) do |t|
      t.string :name
      t.timestamps
    end
    connection.create_table(:active_storage_blobs, force: true) do |t|
      t.string :key, null: false
      t.string :filename, null: false
      t.string :content_type
      t.text :metadata
      t.string :service_name, null: false
      t.bigint :byte_size, null: false
      t.string :checksum
      t.datetime :created_at, null: false
    end
    connection.create_table(:active_storage_attachments, force: true) do |t|
      t.string :name, null: false
      t.references :record, null: false, polymorphic: true, index: false
      t.references :blob, null: false
      t.datetime :created_at, null: false
    end
    connection.create_table(:active_storage_variant_records, force: true) do |t|
      t.belongs_to :blob, null: false
      t.string :variation_digest, null: false
    end
    connection.create_table(:action_text_rich_texts, force: true) do |t|
      t.string :name, null: false
      t.text :body
      t.references :record, null: false, polymorphic: true, index: false
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
      t.vector :embedding, limit: 3, null: false
      t.timestamps
    end
    example.run
  ensure
    clear_enqueued_jobs
    clear_performed_jobs
    connection&.drop_table(:maglev_chunks, if_exists: true)
    connection&.drop_table(:action_text_rich_texts, if_exists: true)
    connection&.drop_table(:active_storage_variant_records, if_exists: true)
    connection&.drop_table(:active_storage_attachments, if_exists: true)
    connection&.drop_table(:active_storage_blobs, if_exists: true)
    connection&.drop_table(:content_customers, if_exists: true)
  end

  before do
    ActiveJob::Base.queue_adapter = :test
    @original_embedding_adapter = Maglev.configuration.embedding_adapter
    @original_embedding_dimensions = Maglev.configuration.embedding_dimensions
    @original_generation_adapter = Maglev.configuration.generation_adapter
    Maglev.configuration.embedding_adapter = ContentEmbeddingAdapter.new
    Maglev.configuration.embedding_dimensions = 3
    Maglev.configuration.generation_adapter = ContentGenerationAdapter.new

    stub_const("ContentCustomer", Class.new(ActiveRecord::Base) do
      self.table_name = "content_customers"
      has_many_attached :contracts
      has_one_attached :summary
      has_rich_text :notes

      has_knowledge do
        expose :name
        expose_attached :contracts, :summary
        expose_rich_text :notes
      end
    end)
  end

  after do
    Maglev.configuration.embedding_adapter = @original_embedding_adapter
    Maglev.configuration.embedding_dimensions = @original_embedding_dimensions
    Maglev.configuration.generation_adapter = @original_generation_adapter
  end

  it "reindexes owners when declared attachments are attached, replaced, or purged" do
    customer = ContentCustomer.create!(name: "Acme")
    clear_enqueued_jobs

    expect do
      customer.contracts.attach(io: StringIO.new("Contract risk"), filename: "contract.txt", content_type: "text/plain")
    end.to enqueue_owner_reindex(customer)

    clear_enqueued_jobs
    customer.summary.attach(io: StringIO.new("Old summary"), filename: "summary.txt", content_type: "text/plain")
    clear_enqueued_jobs

    expect do
      customer.summary.attach(io: StringIO.new("New summary"), filename: "summary.txt", content_type: "text/plain")
    end.to enqueue_owner_reindex(customer)

    clear_enqueued_jobs

    expect do
      customer.contracts.first.purge
    end.to enqueue_owner_reindex(customer)
  end

  it "reindexes owners when declared rich text changes" do
    customer = ContentCustomer.create!(name: "Acme")
    clear_enqueued_jobs

    expect do
      customer.update!(notes: "<p>Support risk</p>")
    end.to enqueue_owner_reindex(customer)
  end

  it "makes search and ask cite attachment and rich-text sources" do
    customer = ContentCustomer.create!(name: "Acme")
    customer.contracts.attach(io: StringIO.new("Contract renewal risk"), filename: "contract.txt", content_type: "text/plain")
    customer.update!(notes: "<p>Visible note</p><script>alert('hidden')</script>")
    perform_enqueued_jobs

    search_result = ContentCustomer.search("risk", limit: 1).first
    answer = ContentCustomer.ask("What sources mention risk?", limit: 1)

    expect(search_result.content).to include("contracts[blob:")
    expect(search_result.content).to include("rich_text.notes.text: Visible note")
    expect(search_result.content).not_to include("alert")
    expect(answer.sources.first[:content]).to include("contracts[blob:")
    expect(answer.text).to eq("Attachment cited: true")
  end

  def enqueue_owner_reindex(customer)
    change { owner_reindex_jobs(customer).size }.by_at_least(1)
  end

  def owner_reindex_jobs(customer)
    enqueued_jobs.select do |job|
      job[:job] == Maglev::ReindexJob &&
        job[:args] == ["ContentCustomer", customer.id]
    end
  end
end
