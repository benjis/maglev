# frozen_string_literal: true

require "rails_helper"
require "generators/maglev/install/install_generator"
require "tmpdir"

RSpec.describe Maglev::Generators::InstallGenerator do
  it "creates an initializer and pgvector migration" do
    Dir.mktmpdir("maglev-generator") do |destination|
      generator = described_class.new([], {}, destination_root: destination)

      generator.invoke_all

      initializer = File.join(destination, "config/initializers/maglev.rb")
      migrations = Dir[File.join(destination, "db/migrate/*_create_maglev_chunks.rb")]

      expect(File.read(initializer)).to include("config.embedding_dimensions = 1536")
      expect(migrations.size).to eq(1)
      expect(File.read(migrations.first)).to include("enable_extension \"vector\"")
      expect(File.read(migrations.first)).to include("create_table :maglev_chunks")
      expect(File.read(migrations.first)).to include("t.string :owner_model_name")
      expect(File.read(migrations.first)).to include("t.vector :embedding, limit: 1536")
    end
  end
end
