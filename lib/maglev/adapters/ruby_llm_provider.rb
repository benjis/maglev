# frozen_string_literal: true

require_relative "../errors"

module Maglev
  module Adapters
    class RubyLLMProvider
      def initialize(provider)
        @provider = provider
      end

      def embed(text)
        result = translate_errors do
          context.embed(
            text,
            model: @provider.model,
            provider: :openai,
            assume_model_exists: true,
            dimensions: @provider.dimensions
          )
        end
        result.vectors.first.is_a?(Array) ? result.vectors.first : result.vectors
      end

      def generate(prompt)
        response = translate_errors do
          context.chat(
            model: @provider.model,
            provider: :openai,
            assume_model_exists: true
          ).ask(prompt)
        end
        response.respond_to?(:content) ? response.content : response.to_s
      end

      private

      def context
        @context ||= begin
          require "ruby_llm"

          RubyLLM.context do |configuration|
            configuration.openai_api_base = @provider.url
            configuration.openai_api_key = @provider.api_key
            configuration.request_timeout = Maglev.configuration.provider_timeout
            configuration.max_retries = 0
            configuration.logger = Maglev.configuration.logger
          end
        end
      end

      def translate_errors
        yield
      rescue RubyLLM::RateLimitError, RubyLLM::OverloadedError,
        RubyLLM::ServerError, RubyLLM::ServiceUnavailableError,
        Faraday::TimeoutError, Faraday::ConnectionFailed => error
        raise RetryableProviderError, error.message
      rescue RubyLLM::Error, RubyLLM::ConfigurationError,
        RubyLLM::ModelNotFoundError => error
        raise PermanentProviderError, error.message
      end
    end
  end
end
