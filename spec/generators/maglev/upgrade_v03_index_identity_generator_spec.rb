# frozen_string_literal: true

require "rails_helper"
require "generators/maglev/upgrade_v03_index_identity/upgrade_v03_index_identity_generator"
require "tmpdir"

RSpec.describe Maglev::Generators::UpgradeV03IndexIdentityGenerator do
  it "adds explicit nullable v0.3 identity metadata without relabelling incompatible v0.2 rows" do
    Dir.mktmpdir("maglev-v03-index-identity") do |destination|
      described_class.new([], {}, destination_root: destination).invoke_all
      migration = Dir[File.join(destination, "db/migrate/*_add_v03_index_identity_to_maglev_chunks.rb")].first
      text = File.read(migration)

      expect(text).to include("add_column :maglev_chunks, :resource_identifier")
      expect(text).to include("add_column :maglev_chunks, :representation_version")
      expect(text).to include("add_column :maglev_chunks, :knowledge_policy_digest")
      expect(text).not_to include("UPDATE maglev_chunks")
      expect(text).to include("Full v0.3 reindex required")
    end
  end
end
