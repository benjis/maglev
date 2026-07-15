# frozen_string_literal: true

require "spec_helper"
require "ostruct"
require "ruby_llm"
require "maglev/adapters/ruby_llm_embedding"
require "maglev/adapters/ruby_llm_generation"

RSpec.describe "Maglev default provider bridge" do
  it "uses isolated endpoint configuration for embedding and generation" do
    contexts = []
    embedding_calls = []
    generation_calls = []

    allow(RubyLLM).to receive(:context) do |&configuration_block|
      configuration = OpenStruct.new
      configuration_block.call(configuration)
      contexts << configuration

      if configuration.openai_api_base.include?("localhost")
        instance_double("EmbeddingContext").tap do |context|
          allow(context).to receive(:embed) do |text, **options|
            embedding_calls << [text, options]
            OpenStruct.new(vectors: [[0.1, 0.2, 0.3]])
          end
        end
      else
        instance_double("GenerationContext").tap do |context|
          chat = instance_double("Chat", ask: OpenStruct.new(content: "answer"))
          allow(context).to receive(:chat) do |**options|
            generation_calls << options
            chat
          end
        end
      end
    end

    embedding_provider = Maglev::ProviderConfiguration.new(
      url: "http://localhost:11434/v1",
      api_key: "local-key",
      model: "local-embedding",
      dimensions: 3
    )
    generation_provider = Maglev::ProviderConfiguration.new(
      url: "https://api.deepseek.com/v1",
      api_key: "deepseek-key",
      model: "deepseek-chat"
    )

    embedding = Maglev::Adapters::RubyLLMEmbedding.new(provider: embedding_provider).embed("text")
    generation = Maglev::Adapters::RubyLLMGeneration.new(provider: generation_provider).generate("prompt")

    expect(embedding).to eq([0.1, 0.2, 0.3])
    expect(generation).to eq("answer")
    expect(contexts.map(&:openai_api_base)).to eq(["http://localhost:11434/v1", "https://api.deepseek.com/v1"])
    expect(contexts.map(&:openai_api_key)).to eq(["local-key", "deepseek-key"])
    expect(contexts.map(&:max_retries)).to eq([0, 0])
    expect(embedding_calls).to eq([["text", {model: "local-embedding", provider: :openai, assume_model_exists: true, dimensions: 3}]])
    expect(generation_calls).to eq([{model: "deepseek-chat", provider: :openai, assume_model_exists: true}])
  end

  it "converts internal provider errors to Maglev errors" do
    allow(RubyLLM).to receive(:context) do
      instance_double("GenerationContext").tap do |context|
        allow(context).to receive(:chat).and_raise(RubyLLM::RateLimitError, "busy")
      end
    end
    provider = Maglev::ProviderConfiguration.new(url: "https://example.test/v1", api_key: "key", model: "model")

    expect do
      Maglev::Adapters::RubyLLMGeneration.new(provider: provider).generate("prompt")
    end.to raise_error(Maglev::RetryableProviderError, "busy")
  end
end
