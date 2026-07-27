# frozen_string_literal: true

require "rails_helper"
require "rake"
require_relative "../dummy/db/migrate/20260719000100_add_source_identity_to_maglev_chunks"
require_relative "../dummy/db/migrate/20260727000100_add_context_to_maglev_chunks"

Rake::Task.define_task(:environment) unless Rake::Task.task_defined?(:environment)
load File.expand_path("../../lib/tasks/maglev.rake", __dir__) unless Rake::Task.task_defined?("maglev:reindex")

RSpec.describe "Maglev dummy-app upgrade" do
  it "migrates legacy storage, performs a full reindex, and rolls back" do
    connection = ActiveRecord::Base.connection
    connection.transaction(requires_new: true) do
      create_legacy_tables(connection)
      stub_const("UpgradeProduct", Class.new(ActiveRecord::Base) do
        self.table_name = "upgrade_products"
        maglev_resource :upgrade_products do
          knowledge do
            content :name
            context :industry
          end
        end
      end)
      product = UpgradeProduct.create!(name: "Battery", industry: "Energy")
      configure_embeddings
      migration = AddSourceIdentityToMaglevChunks.new
      context_migration = AddContextToMaglevChunks.new

      migration.migrate(:up)
      context_migration.migrate(:up)
      Maglev::Chunk.reset_column_information
      Maglev::IndexState.reset_column_information
      Rake::Task["maglev:reindex"].reenable
      Rake::Task["maglev:reindex"].invoke("UpgradeProduct")

      chunk = Maglev::Chunk.find_by!(owner_type: "UpgradeProduct", owner_id: product.id)
      expect(chunk).to have_attributes(
        source_identity: "name",
        source_type: "attribute",
        context: {"industry" => "Energy"}
      )
      expect(product.maglev_index_status).to have_attributes(status: :ready, chunk_count: 1)

      context_migration.migrate(:down)
      migration.migrate(:down)
      expect(connection.column_exists?(:maglev_chunks, :context)).to be(false)
      expect(connection.column_exists?(:maglev_chunks, :source_identity)).to be(false)
      expect(connection.table_exists?(:maglev_index_states)).to be(false)
      raise ActiveRecord::Rollback
    end
  ensure
    Maglev::Chunk.reset_column_information
    Rake::Task["maglev:reindex"].reenable if Rake::Task.task_defined?("maglev:reindex")
  end

  def create_legacy_tables(connection)
    connection.drop_table(:maglev_index_states, if_exists: true)
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
    connection.create_table(:upgrade_products, force: true) do |t|
      t.string :name
      t.string :industry
      t.timestamps
    end
    Maglev::Chunk.reset_column_information
  end

  def configure_embeddings
    adapter = Class.new do
      def maglev_adapter_id = "test.dummy_app_upgrade"
      def maglev_adapter_version = "1"
      def embed(_text) = [1.0, 0.0, 0.0]
    end.new
    Maglev.configuration.embedding_adapter = adapter
    Maglev.configuration.embedding_dimensions = 3
    Maglev.configuration.vector_store = nil
  end
end
