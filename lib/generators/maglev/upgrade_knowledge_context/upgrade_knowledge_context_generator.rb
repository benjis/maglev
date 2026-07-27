# frozen_string_literal: true

require "rails/generators"

module Maglev
  module Generators
    class UpgradeKnowledgeContextGenerator < Rails::Generators::Base
      def create_migration
        create_file "db/migrate/#{migration_timestamp}_add_context_to_maglev_chunks.rb", <<~RUBY
          # frozen_string_literal: true

          class AddContextToMaglevChunks < ActiveRecord::Migration[7.1]
            def change
              add_column :maglev_chunks, :context, :jsonb, null: false, default: {}
            end
          end
        RUBY
      end

      private

      def migration_timestamp = Time.now.utc.strftime("%Y%m%d%H%M%S")
    end
  end
end
