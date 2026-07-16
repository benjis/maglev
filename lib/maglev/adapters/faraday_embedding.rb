# frozen_string_literal: true

require_relative "../embedding_adapter"
require_relative "faraday_client"

module Maglev
  module Adapters
    # Embedding adapter using Faraday directly
    # Compatible with OpenAI embedding API format
    class FaradayEmbedding < EmbeddingAdapter
      def initialize(provider: Maglev.configuration.embedding_provider, connection: nil)
        @provider = provider
        @client = FaradayClient.new(@provider, connection: connection)
      end

      def embed(text)
        payload = build_payload(text)
        response = @client.post("embeddings", payload)
        parse_response(response)
      end

      private

      def build_payload(text)
        {
          model: @provider.model,
          input: text,
          dimensions: @provider.dimensions
        }.compact
      end

      def parse_response(response)
        data = response["data"]
        unless data.is_a?(Array) && data.one?
          raise PermanentProviderError, "Embedding provider returned invalid data"
        end

        embedding = data.dig(0, "embedding")
        unless embedding.is_a?(Array) && embedding.any?
          raise PermanentProviderError, "Embedding provider returned an invalid embedding"
        end

        embedding
      end
    end
  end
end
