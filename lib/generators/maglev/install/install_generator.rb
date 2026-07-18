# frozen_string_literal: true

require "rails/generators"

module Maglev
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)
      class_option :embedding_dimensions, type: :numeric, default: 1536

      def create_initializer
        create_file "config/initializers/maglev.rb", <<~RUBY
          # frozen_string_literal: true

          Maglev.configure do |config|
            config.embedding_provider do |provider|
              provider.url = ENV.fetch("MAGLEV_EMBEDDING_URL", "https://api.openai.com/v1")
              provider.api_key = ENV["MAGLEV_EMBEDDING_API_KEY"]
              provider.model = "text-embedding-3-small"
              provider.dimensions = #{options[:embedding_dimensions]}
            end

            config.generation_provider do |provider|
              provider.url = ENV.fetch("MAGLEV_GENERATION_URL", "https://api.openai.com/v1")
              provider.api_key = ENV["MAGLEV_GENERATION_API_KEY"]
              provider.model = "gpt-4.1-mini"
            end

            config.chunk_size = 1000
          end
        RUBY
      end

      def create_migration
        create_file "db/migrate/#{migration_timestamp}_create_maglev_chunks.rb", <<~RUBY
          # frozen_string_literal: true

          class CreateMaglevChunks < ActiveRecord::Migration[7.1]
            def change
              enable_extension "vector"

              create_table :maglev_chunks do |t|
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
                t.vector :embedding, limit: #{options[:embedding_dimensions]}, null: false
                t.timestamps
              end

              add_index :maglev_chunks, [:owner_type, :owner_id, :source, :chunk_index], unique: true, name: "index_maglev_chunks_on_owner_source_chunk"
              add_index :maglev_chunks, :owner_model_name
              add_index :maglev_chunks, [:owner_model_name, :owner_id, :source_type, :index_version], name: "index_maglev_chunks_for_filtered_retrieval"
              add_index :maglev_chunks, :tenant_id
              add_index :maglev_chunks, :embedding, using: :hnsw, opclass: :vector_cosine_ops

              create_table :maglev_index_states do |t|
                t.string :owner_type, null: false
                t.bigint :owner_id, null: false
                t.string :status, null: false
                t.string :active_index_version, limit: 64
                t.integer :chunk_count, null: false, default: 0
                t.datetime :last_success_at
                t.string :latest_failure_class
                t.datetime :latest_failure_at
                t.boolean :rebuild_required, null: false, default: false
                t.timestamps
              end
              add_index :maglev_index_states, [:owner_type, :owner_id], unique: true
            end
          end
        RUBY
      end

      private

      def migration_timestamp
        Time.now.utc.strftime("%Y%m%d%H%M%S")
      end
    end
  end
end
