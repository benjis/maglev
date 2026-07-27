# frozen_string_literal: true

require "rails/generators"

module Maglev
  module Generators
    class UpgradeV03IndexIdentityGenerator < Rails::Generators::Base
      def create_migration
        create_file "db/migrate/#{migration_timestamp}_add_v03_index_identity_to_maglev_chunks.rb", <<~RUBY
          # frozen_string_literal: true

          class AddV03IndexIdentityToMaglevChunks < ActiveRecord::Migration[7.1]
            def change
              # Full v0.3 reindex required. Existing v0.2 rows remain unlabelled and incompatible.
              add_column :maglev_chunks, :resource_identifier, :string
              add_column :maglev_chunks, :representation_version, :string
              add_column :maglev_chunks, :knowledge_policy_digest, :string, limit: 64
              add_index :maglev_chunks,
                [:resource_identifier, :owner_id, :source_type, :index_version],
                name: "index_maglev_chunks_for_v03_filtered_retrieval"
            end
          end
        RUBY
      end

      private

      def migration_timestamp = Time.now.utc.strftime("%Y%m%d%H%M%S")
    end
  end
end
