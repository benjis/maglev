# frozen_string_literal: true

require_relative "../generation_adapter"
require_relative "faraday_client"

module Maglev
  module Adapters
    # Generation adapter using Faraday directly
    # Compatible with OpenAI chat completions API format
    class FaradayGeneration < GenerationAdapter
      def initialize(provider: Maglev.configuration.generation_provider, connection: nil)
        @provider = provider
        @client = FaradayClient.new(@provider, connection: connection)
      end

      def generate(prompt)
        payload = build_payload(prompt)
        response = @client.post("chat/completions", payload)
        parse_response(response)
      end

      private

      def build_payload(prompt)
        {
          model: @provider.model,
          messages: [
            {role: "user", content: prompt}
          ],
          stream: false
        }
      end

      def parse_response(response)
        choices = response["choices"]
        unless choices.is_a?(Array) && choices.any?
          raise PermanentProviderError, "Generation provider returned invalid choices"
        end

        content = choices.dig(0, "message", "content")
        unless content.is_a?(String) && !content.strip.empty?
          raise PermanentProviderError, "Generation provider returned invalid content"
        end

        content
      end
    end
  end
end
