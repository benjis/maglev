# frozen_string_literal: true

require "rails_helper"
require "generators/maglev/upgrade_source_identity/upgrade_source_identity_generator"
require "tmpdir"

RSpec.describe Maglev::Generators::UpgradeSourceIdentityGenerator do
  it "creates a reversible metadata migration that requires a full reindex" do
    Dir.mktmpdir("maglev-source-upgrade") do |destination|
      described_class.new([], {}, destination_root: destination).invoke_all
      migration = Dir[File.join(destination, "db/migrate/*_add_source_identity_to_maglev_chunks.rb")].first
      text = File.read(migration)
      expect(text).to include("add_column :maglev_chunks, :source_identity")
      expect(text).to include("add_column :maglev_chunks, :source_type")
      expect(text).to include("def down")
      expect(text).to include("UPDATE maglev_chunks SET source_identity = source, source_type = 'snapshot'")
      expect(text).to include("change_column_null :maglev_chunks, :source_identity, false")
    end
  end
end
