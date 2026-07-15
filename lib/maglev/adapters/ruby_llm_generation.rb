# frozen_string_literal: true

require_relative "../configuration"
require_relative "../generation_adapter"
require_relative "../provider_configuration"
require_relative "ruby_llm_provider"

module Maglev
  module Adapters
    class RubyLLMGeneration < GenerationAdapter
      def initialize(provider: Maglev.configuration.generation_provider, model: nil)
        configuration = provider.to_h
        configuration[:model] = model if model
        @client = RubyLLMProvider.new(ProviderConfiguration.new(**configuration))
      end

      def generate(prompt)
        @client.generate(prompt)
      end
    end
  end
end
