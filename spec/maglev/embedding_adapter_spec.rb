# frozen_string_literal: true

require "spec_helper"
require "maglev/embedding_adapter"
require "maglev/adapters/faraday_embedding"

RSpec.describe Maglev::EmbeddingAdapter do
  it "requires concrete adapters to implement embed" do
    expect { described_class.new.embed("query") }.to raise_error(NotImplementedError, /embed/)
  end

  it "requires concrete adapters to declare a stable identity" do
    adapter = described_class.new

    expect { adapter.maglev_adapter_id }.to raise_error(Maglev::ConfigurationError, /adapter ID/)
    expect { adapter.maglev_adapter_version }.to raise_error(Maglev::ConfigurationError, /adapter version/)
  end

  it "gives the built-in adapter an explicit stable identity" do
    adapter = Maglev::Adapters::FaradayEmbedding.allocate

    expect(adapter.maglev_adapter_id).to eq("maglev.openai_compatible_http_embedding")
    expect(adapter.maglev_adapter_version).to eq("1")
  end
end
