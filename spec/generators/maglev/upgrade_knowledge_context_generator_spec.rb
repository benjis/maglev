# frozen_string_literal: true

require "rails_helper"
require "generators/maglev/upgrade_knowledge_context/upgrade_knowledge_context_generator"
require "tmpdir"

RSpec.describe Maglev::Generators::UpgradeKnowledgeContextGenerator do
  it "creates a reversible migration that stores knowledge context outside embedded content" do
    Dir.mktmpdir("maglev-knowledge-context-upgrade") do |destination|
      described_class.new([], {}, destination_root: destination).invoke_all
      migration = Dir[File.join(destination, "db/migrate/*_add_context_to_maglev_chunks.rb")].first
      text = File.read(migration)

      expect(text).to include(
        "add_column :maglev_chunks, :context, :jsonb, null: false, default: {}"
      )
    end
  end
end
