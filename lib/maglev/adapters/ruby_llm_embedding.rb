# frozen_string_literal: true

require_relative "../embedding_adapter"
require_relative "../provider_configuration"
require_relative "ruby_llm_provider"

module Maglev
  module Adapters
    class RubyLLMEmbedding < EmbeddingAdapter
      def initialize(provider: Maglev.configuration.embedding_provider, model: nil, dimensions: nil)
        configuration = provider.to_h
        configuration[:model] = model if model
        configuration[:dimensions] = dimensions if dimensions
        @client = RubyLLMProvider.new(ProviderConfiguration.new(**configuration))
      end

      def embed(text)
        @client.embed(text)
      end
    end
  end
end
