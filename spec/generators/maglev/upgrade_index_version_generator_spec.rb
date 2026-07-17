# frozen_string_literal: true

require "rails_helper"
require "generators/maglev/upgrade_index_version/upgrade_index_version_generator"
require "tmpdir"

RSpec.describe Maglev::Generators::UpgradeIndexVersionGenerator do
  it "creates one nullable index-version migration without backfilling legacy rows" do
    Dir.mktmpdir("maglev-upgrade-generator") do |destination|
      generator = described_class.new([], {}, destination_root: destination)

      generator.invoke_all

      migrations = Dir[File.join(destination, "db/migrate/*_add_index_version_to_maglev_chunks.rb")]
      expect(migrations.size).to eq(1)

      migration = File.read(migrations.first)
      expect(migration).to include("add_column :maglev_chunks, :index_version, :string, limit: 64")
      expect(migration).not_to include("null: false")
      expect(migration).not_to match(/UPDATE|change_column_null|[0-9a-f]{64}/)
    end
  end
end
