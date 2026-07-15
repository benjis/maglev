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

      expect(File.read(initializer)).to include("config.embedding_provider do |provider|")
      expect(File.read(initializer)).to include("provider.dimensions = 1536")
      expect(File.read(initializer)).to include("config.generation_provider do |provider|")
      expect(migrations.size).to eq(1)
      expect(File.read(migrations.first)).to include("enable_extension \"vector\"")
      expect(File.read(migrations.first)).to include("create_table :maglev_chunks")
      expect(File.read(migrations.first)).to include("t.string :owner_model_name")
      expect(File.read(migrations.first)).to include("t.vector :embedding, limit: 1536")
      expect(File).not_to exist(File.join(destination, "config/initializers/ruby_llm.rb"))
      expect(described_class.class_options.keys.map(&:to_sym)).not_to include(:ruby_llm_initializer)
    end
  end

  it "uses one embedding dimension option for the initializer and migration" do
    Dir.mktmpdir("maglev-generator") do |destination|
      generator = described_class.new([], {embedding_dimensions: 1024}, destination_root: destination)

      generator.invoke_all

      initializer = File.join(destination, "config/initializers/maglev.rb")
      migration = Dir[File.join(destination, "db/migrate/*_create_maglev_chunks.rb")].first

      expect(File.read(initializer)).to include("provider.dimensions = 1024")
      expect(File.read(migration)).to include("t.vector :embedding, limit: 1024")
    end
  end
end
