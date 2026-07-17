# frozen_string_literal: true

require "spec_helper"
require "maglev"

RSpec.describe Maglev do
  it "yields the configuration shell" do
    yielded = nil

    described_class.configure do |config|
      yielded = config
    end

    expect(yielded).to be_a(Maglev::Configuration)
    expect(yielded).to be(described_class.configuration)
  end

  it "configures embedding and generation endpoints independently" do
    configuration = Maglev::Configuration.new

    configuration.embedding_provider do |provider|
      provider.url = "http://localhost:11434/v1"
      provider.api_key = "local"
      provider.model = "local-embedding"
      provider.dimensions = 1024
    end
    configuration.generation_provider do |provider|
      provider.url = "https://api.deepseek.com/v1"
      provider.api_key = "secret"
      provider.model = "deepseek-chat"
    end

    expect(configuration.embedding_provider.to_h).to eq(
      url: "http://localhost:11434/v1",
      api_key: "local",
      model: "local-embedding",
      dimensions: 1024
    )
    expect(configuration.generation_provider.to_h).to eq(
      url: "https://api.deepseek.com/v1",
      api_key: "secret",
      model: "deepseek-chat"
    )
  end

  it "keeps legacy model settings synchronized with provider configuration" do
    configuration = Maglev::Configuration.new

    configuration.embedding_model = "legacy-embedding"
    configuration.embedding_dimensions = 768
    configuration.generation_model = "legacy-generation"

    expect(configuration.embedding_provider.model).to eq("legacy-embedding")
    expect(configuration.embedding_provider.dimensions).to eq(768)
    expect(configuration.generation_provider.model).to eq("legacy-generation")
  end

  it "provides index identity overrides with a stable application default" do
    configuration = Maglev::Configuration.new

    expect(configuration.embedding_adapter_id).to be_nil
    expect(configuration.embedding_adapter_version).to be_nil
    expect(configuration.application_index_version).to eq("1")

    configuration.embedding_adapter_id = "custom.embedding"
    configuration.embedding_adapter_version = "3"
    configuration.application_index_version = "release-2"

    expect(configuration.embedding_adapter_id).to eq("custom.embedding")
    expect(configuration.embedding_adapter_version).to eq("3")
    expect(configuration.application_index_version).to eq("release-2")
  end
end
