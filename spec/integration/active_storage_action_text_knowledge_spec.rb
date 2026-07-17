# frozen_string_literal: true

require "rails_helper"
require "active_job/test_helper"
require "stringio"

class ContentEmbeddingAdapter
  def maglev_adapter_id = "test.active_storage_action_text"

  def maglev_adapter_version = "1"

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
      t.references :content_account
      t.timestamps
    end
    connection.create_table(:content_accounts, force: true) do |t|
      t.string :name
      t.references :content_organization
      t.timestamps
    end
    connection.create_table(:content_organizations, force: true) do |t|
      t.string :name
      t.timestamps
    end
    ActiveStorage::Attachment.delete_all
    ActiveStorage::VariantRecord.delete_all
    ActionText::RichText.delete_all
    ActiveStorage::Blob.delete_all
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
    example.run
  ensure
    clear_enqueued_jobs
    clear_performed_jobs
    connection&.drop_table(:maglev_chunks, if_exists: true)
    connection&.drop_table(:content_customers, if_exists: true)
    connection&.drop_table(:content_accounts, if_exists: true)
    connection&.drop_table(:content_organizations, if_exists: true)
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
      belongs_to :account, class_name: "ContentAccount", inverse_of: :customers, foreign_key: :content_account_id, optional: true
      has_many_attached :contracts
      has_one_attached :summary
      has_rich_text :notes
    end)
    stub_const("ContentAccount", Class.new(ActiveRecord::Base) do
      self.table_name = "content_accounts"
      belongs_to :organization, class_name: "ContentOrganization", inverse_of: :accounts, foreign_key: :content_organization_id, optional: true
      has_many :customers, class_name: "ContentCustomer", inverse_of: :account, foreign_key: :content_account_id
    end)
    stub_const("ContentOrganization", Class.new(ActiveRecord::Base) do
      self.table_name = "content_organizations"
      has_many :accounts, class_name: "ContentAccount", inverse_of: :organization, foreign_key: :content_organization_id
    end)

    ContentCustomer.has_knowledge do
      expose :name
      expose_attached :contracts, :summary
      expose_rich_text :notes
    end
    ContentAccount.has_knowledge do
      expose :name
      include_related :customers, depth: 1, limit: 10
    end
    ContentOrganization.has_knowledge do
      expose :name
      include_related :accounts, depth: 2, limit: 10
    end
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

  it "reindexes transitive knowledge owners when a declared content source changes" do
    organization = ContentOrganization.create!(name: "Umbrella")
    account = ContentAccount.create!(name: "Enterprise", organization: organization)
    customer = ContentCustomer.create!(name: "Acme", account: account)
    clear_enqueued_jobs

    customer.contracts.attach(io: StringIO.new("Contract risk"), filename: "contract.txt", content_type: "text/plain")

    expect(owner_reindex_jobs(customer)).not_to be_empty
    expect(owner_reindex_jobs(account)).not_to be_empty
    expect(owner_reindex_jobs(organization)).not_to be_empty

    clear_enqueued_jobs
    customer.update!(notes: "<p>Renewal risk</p>")

    expect(owner_reindex_jobs(customer)).not_to be_empty
    expect(owner_reindex_jobs(account)).not_to be_empty
    expect(owner_reindex_jobs(organization)).not_to be_empty
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
        job[:args] == [customer.class.name, customer.id]
    end
  end
end
