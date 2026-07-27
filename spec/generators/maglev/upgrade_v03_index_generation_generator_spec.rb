# frozen_string_literal: true

require "rails_helper"
require "generators/maglev/upgrade_v03_index_generation/upgrade_v03_index_generation_generator"
require "tmpdir"

RSpec.describe Maglev::Generators::UpgradeV03IndexGenerationGenerator do
  it "adds isolated chunk generations and persistent atomic cutover state" do
    Dir.mktmpdir("maglev-v03-index-generation") do |destination|
      described_class.new([], {}, destination_root: destination).invoke_all
      migration = Dir[File.join(destination, "db/migrate/*_add_v03_index_generations.rb")].first
      text = File.read(migration)

      expect(text).to include("add_column :maglev_chunks, :generation")
      expect(text).to include("create_table :maglev_index_generations")
      expect(text).to include("where: \"status = 'active'\"")
      expect(text).to include("index_maglev_chunks_on_generation_owner_source_chunk")
      expect(text).not_to include("delete_all")
    end
  end
end
