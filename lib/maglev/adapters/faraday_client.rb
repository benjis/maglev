# frozen_string_literal: true

require "faraday"
require "json"

require_relative "../configuration"
require_relative "../errors"

module Maglev
  module Adapters
    # Shared HTTP client for OpenAI-compatible APIs
    class FaradayClient
      RETRYABLE_STATUSES = [408, 409, 425, 429].freeze

      attr_reader :config

      def initialize(config, connection: nil)
        @config = config
        @connection = connection
      end

      def post(path, payload)
        response = connection.post(endpoint(path)) do |req|
          req.headers["Content-Type"] = "application/json"
          req.headers["Authorization"] = "Bearer #{@config.api_key}" if @config.api_key
          req.body = payload
        end

        handle_response(response)
      rescue Faraday::TimeoutError, Faraday::ConnectionFailed => error
        raise Maglev::RetryableProviderError, error.message
      rescue Faraday::ParsingError => error
        status = error.response_status
        error_class = (status && retryable_status?(status)) ? Maglev::RetryableProviderError : Maglev::PermanentProviderError
        prefix = status ? "HTTP #{status}: " : ""
        raise error_class, "#{prefix}Provider returned invalid JSON: #{error.message}"
      end

      private

      def connection
        @connection ||= Faraday.new(url: @config.url) do |faraday|
          timeout = Maglev.configuration.provider_timeout
          faraday.options.timeout = timeout
          faraday.options.open_timeout = timeout
          faraday.options.read_timeout = timeout
          faraday.options.write_timeout = timeout
          faraday.request :json
          faraday.adapter Faraday.default_adapter
        end
      end

      def endpoint(path)
        "#{@config.url.to_s.delete_suffix("/")}/#{path.to_s.delete_prefix("/")}"
      end

      def handle_response(response)
        body = decode_body(response.body, strict: response.success?)
        unless response.success?
          error_class = retryable_status?(response.status) ? Maglev::RetryableProviderError : Maglev::PermanentProviderError
          raise error_class, error_message(response, body)
        end

        body
      end

      def retryable_status?(status)
        RETRYABLE_STATUSES.include?(status) || status.between?(500, 599)
      end

      def decode_body(body, strict:)
        return body if body.is_a?(Hash)

        JSON.parse(body.to_s)
      rescue JSON::ParserError => error
        raise Maglev::PermanentProviderError, "Provider returned invalid JSON: #{error.message}" if strict

        body
      end

      def error_message(response, body)
        provider_message = if body.is_a?(Hash)
          body.dig("error", "message") || body.dig(:error, :message)
        else
          body.to_s
        end
        message = "HTTP #{response.status}"
        message = "#{message}: #{provider_message}" unless provider_message.to_s.empty?
        request_id = response.headers["x-request-id"]
        request_id ? "#{message} (request_id=#{request_id})" : message
      end
    end
  end
end
