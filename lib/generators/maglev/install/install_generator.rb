# frozen_string_literal: true

require "rails/generators"

module Maglev
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      def create_initializer
        create_file "config/initializers/maglev.rb", <<~RUBY
          # frozen_string_literal: true

          Maglev.configure do |config|
            config.embedding_model = "text-embedding-3-small"
            config.embedding_dimensions = 1536
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
                t.integer :chunk_index, null: false
                t.text :content, null: false
                t.string :content_checksum, null: false
                t.string :embedding_model, null: false
                t.vector :embedding, limit: 1536, null: false
                t.timestamps
              end

              add_index :maglev_chunks, [:owner_type, :owner_id, :source, :chunk_index], unique: true, name: "index_maglev_chunks_on_owner_source_chunk"
              add_index :maglev_chunks, :owner_model_name
              add_index :maglev_chunks, :embedding, using: :hnsw, opclass: :vector_cosine_ops
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
