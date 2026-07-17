# frozen_string_literal: true

require "spec_helper"
require "maglev/configuration"
require "maglev/index_identity"

class VersionedEmbeddingAdapter
  def maglev_adapter_id = "test.embedding"
  def maglev_adapter_version = "1"
end

class UnversionedEmbeddingAdapter
end

RSpec.describe Maglev::IndexIdentity do
  def configuration
    Maglev::Configuration.new
  end

  def fingerprint(configuration: self.configuration, adapter: VersionedEmbeddingAdapter.new, chunk_size: 1000)
    described_class.new(configuration: configuration, adapter: adapter, chunk_size: chunk_size).to_s
  end

  it "hashes the exact versioned payload in its fixed field order" do
    expect(fingerprint).to eq("72e3dde21998f405f9d59e3f1d3e1b75f7744bffc92141c5a653e71688af5f57")
  end

  it "does not allow callers to override the chunking algorithm version" do
    keyword_parameters = described_class.instance_method(:initialize).parameters
      .filter_map { |type, name| name if type == :key || type == :keyreq }

    expect(keyword_parameters).to contain_exactly(:configuration, :adapter, :chunk_size)
  end

  it "changes when the embedding model changes" do
    changed = configuration
    changed.embedding_model = "another-model"

    expect(fingerprint(configuration: changed)).not_to eq(fingerprint)
  end

  it "changes when the embedding dimensions change" do
    changed = configuration
    changed.embedding_dimensions = 768

    expect(fingerprint(configuration: changed)).not_to eq(fingerprint)
  end

  it "changes when the adapter ID changes" do
    changed = Class.new(VersionedEmbeddingAdapter) do
      def maglev_adapter_id = "other.embedding"
    end.new

    expect(fingerprint(adapter: changed)).not_to eq(fingerprint)
  end

  it "changes when the adapter version changes" do
    changed = Class.new(VersionedEmbeddingAdapter) do
      def maglev_adapter_version = "2"
    end.new

    expect(fingerprint(adapter: changed)).not_to eq(fingerprint)
  end

  it "includes the chunking algorithm version" do
    original = fingerprint
    stub_const("Maglev::Chunker::ALGORITHM_VERSION", "changed")

    expect(fingerprint).not_to eq(original)
  end

  it "changes when the chunk size changes" do
    expect(fingerprint(chunk_size: 500)).not_to eq(fingerprint)
  end

  it "changes when the application index version changes" do
    changed = configuration
    changed.application_index_version = "2"

    expect(fingerprint(configuration: changed)).not_to eq(fingerprint)
  end

  it "rejects a custom adapter without explicit identity" do
    expect { fingerprint(adapter: UnversionedEmbeddingAdapter.new) }
      .to raise_error(Maglev::ConfigurationError, /adapter ID/)
  end

  it "uses configuration overrides before adapter identity methods" do
    configured = configuration
    configured.embedding_adapter_id = "configured.embedding"
    configured.embedding_adapter_version = "42"

    expect { fingerprint(configuration: configured, adapter: UnversionedEmbeddingAdapter.new) }.not_to raise_error
  end

  it "rejects invalid string identity components" do
    invalid_values = {
      embedding_model: [nil, "", :model],
      embedding_adapter_id: ["", :adapter],
      embedding_adapter_version: ["", 1],
      application_index_version: [nil, "", 1]
    }

    invalid_values.each do |attribute, values|
      values.each do |value|
        invalid = configuration
        invalid.public_send("#{attribute}=", value)

        expect { fingerprint(configuration: invalid) }
          .to raise_error(Maglev::ConfigurationError, /must be a non-empty string/)
      end
    end
  end

  it "rejects an invalid chunking algorithm version" do
    [nil, "", 1].each do |value|
      stub_const("Maglev::Chunker::ALGORITHM_VERSION", value)

      expect { fingerprint }.to raise_error(Maglev::ConfigurationError, /chunking algorithm version/)
    end
  end

  it "rejects invalid dimensions and chunk sizes" do
    [0, 1.5, "1536"].each do |value|
      invalid_dimensions = configuration
      invalid_dimensions.embedding_dimensions = value

      expect { fingerprint(configuration: invalid_dimensions) }
        .to raise_error(Maglev::ConfigurationError, /dimensions/)
    end

    [0, 1.5, "1000"].each do |value|
      expect { fingerprint(chunk_size: value) }
        .to raise_error(Maglev::ConfigurationError, /chunk size/)
    end
  end
end
