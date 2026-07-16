# frozen_string_literal: true

require "spec_helper"
require "json"
require "faraday"
require "maglev/configuration"
require "maglev/errors"
require "maglev/embedding_adapter"
require "maglev/generation_adapter"
require "maglev/adapters/faraday_embedding"
require "maglev/adapters/faraday_generation"

RSpec.describe "Maglev Faraday provider adapters" do
  def test_connection(&stubs)
    Faraday.new do |connection|
      connection.adapter :test, Faraday::Adapter::Test::Stubs.new(&stubs)
    end
  end

  def parsed_request_body(body)
    JSON.parse(body.is_a?(String) ? body : JSON.generate(body))
  end

  around do |example|
    original_configuration = Maglev.instance_variable_get(:@configuration)
    Maglev.instance_variable_set(:@configuration, Maglev::Configuration.new)
    example.run
  ensure
    Maglev.instance_variable_set(:@configuration, original_configuration)
  end

  it "uses the configured embedding provider and sends its request contract" do
    request_headers = nil
    request_body = nil
    Maglev.configuration.embedding_provider do |provider|
      provider.url = "http://localhost:11434/v1"
      provider.api_key = "local-key"
      provider.model = "local-embedding"
      provider.dimensions = 3
    end
    connection = test_connection do |stub|
      stub.post("/v1/embeddings") do |environment|
        request_headers = environment.request_headers.dup
        request_body = environment.body
        [200, {"Content-Type" => "application/json"}, {data: [{embedding: [0.1, 0.2, 0.3]}]}.to_json]
      end
    end

    embedding = Maglev::Adapters::FaradayEmbedding.new(connection: connection).embed("text")

    expect(embedding).to eq([0.1, 0.2, 0.3])
    expect(request_headers["Authorization"]).to eq("Bearer local-key")
    expect(parsed_request_body(request_body)).to eq(
      "model" => "local-embedding",
      "input" => "text",
      "dimensions" => 3
    )
  end

  it "uses the configured generation provider and sends its request contract" do
    request_headers = nil
    request_body = nil
    Maglev.configuration.generation_provider do |provider|
      provider.url = "https://api.deepseek.com/v1"
      provider.api_key = "deepseek-key"
      provider.model = "deepseek-chat"
    end
    connection = test_connection do |stub|
      stub.post("/v1/chat/completions") do |environment|
        request_headers = environment.request_headers.dup
        request_body = environment.body
        [200, {"Content-Type" => "application/json"}, {choices: [{message: {content: "answer"}}]}.to_json]
      end
    end

    answer = Maglev::Adapters::FaradayGeneration.new(connection: connection).generate("prompt")

    expect(answer).to eq("answer")
    expect(request_headers["Authorization"]).to eq("Bearer deepseek-key")
    expect(parsed_request_body(request_body)).to eq(
      "model" => "deepseek-chat",
      "messages" => [{"role" => "user", "content" => "prompt"}],
      "stream" => false
    )
  end

  it "keeps explicit providers independent and omits authorization without an API key" do
    provider = Maglev::ProviderConfiguration.new(
      url: "https://provider.example/v1",
      model: "custom-embedding",
      dimensions: 2
    )
    request_headers = nil
    request_body = nil
    connection = test_connection do |stub|
      stub.post("/v1/embeddings") do |environment|
        request_headers = environment.request_headers.dup
        request_body = environment.body
        [200, {"Content-Type" => "application/json"}, {data: [{embedding: [0.4, 0.5]}]}.to_json]
      end
    end

    embedding = Maglev::Adapters::FaradayEmbedding.new(provider: provider, connection: connection).embed("query")

    expect(embedding).to eq([0.4, 0.5])
    expect(request_headers).not_to include("Authorization")
    expect(parsed_request_body(request_body)["model"]).to eq("custom-embedding")
  end

  describe Maglev::Adapters::FaradayClient do
    def provider
      Maglev::ProviderConfiguration.new(url: "https://provider.example/v1", api_key: "key")
    end

    def client_for_response(status:, body:, headers: {"Content-Type" => "application/json"})
      connection = test_connection do |stub|
        stub.post("/v1/test") { [status, headers, body] }
      end
      described_class.new(provider, connection: connection)
    end

    it "classifies transient HTTP statuses as retryable" do
      [408, 409, 425, 429, 500, 503].each do |status|
        client = client_for_response(status: status, body: {error: {message: "busy"}}.to_json)

        expect { client.post("test", {}) }
          .to raise_error(Maglev::RetryableProviderError, /HTTP #{status}.*busy/)
      end
    end

    it "classifies other unsuccessful HTTP statuses as permanent" do
      [301, 400, 401, 403, 404].each do |status|
        client = client_for_response(status: status, body: {error: {message: "invalid"}}.to_json)

        expect { client.post("test", {}) }
          .to raise_error(Maglev::PermanentProviderError, /HTTP #{status}.*invalid/)
      end
    end

    it "includes the provider request id in HTTP errors" do
      client = client_for_response(
        status: 429,
        body: {error: {message: "busy"}}.to_json,
        headers: {"Content-Type" => "application/json", "x-request-id" => "req-123"}
      )

      expect { client.post("test", {}) }
        .to raise_error(Maglev::RetryableProviderError, /request_id=req-123/)
    end

    it "prioritizes retryable HTTP status when an error response is not JSON" do
      client = client_for_response(
        status: 503,
        body: "temporarily unavailable",
        headers: {"Content-Type" => "text/plain"}
      )

      expect { client.post("test", {}) }
        .to raise_error(Maglev::RetryableProviderError, /HTTP 503.*temporarily unavailable/)
    end

    it "translates provider timeouts and connection failures" do
      [Faraday::TimeoutError.new("slow"), Faraday::ConnectionFailed.new("offline")].each do |failure|
        connection = Faraday.new do |builder|
          builder.adapter :test, Faraday::Adapter::Test::Stubs.new { |stub| stub.post("/v1/test") { raise failure } }
        end
        client = described_class.new(provider, connection: connection)

        expect { client.post("test", {}) }
          .to raise_error(Maglev::RetryableProviderError, failure.message)
      end
    end

    it "translates malformed successful JSON into a permanent provider error" do
      client = client_for_response(status: 200, body: "not-json")

      expect { client.post("test", {}) }
        .to raise_error(Maglev::PermanentProviderError, /invalid JSON/)
    end

    it "applies the configured provider timeout to Faraday" do
      Maglev.configuration.provider_timeout = 7
      connection = described_class.new(provider).send(:connection)

      expect(connection.options.timeout).to eq(7)
      expect(connection.options.open_timeout).to eq(7)
      expect(connection.options.read_timeout).to eq(7)
      expect(connection.options.write_timeout).to eq(7)
    end
  end

  describe "successful response validation" do
    def embedding_adapter_for(response)
      provider = Maglev::ProviderConfiguration.new(
        url: "https://provider.example/v1",
        model: "embedding-model",
        dimensions: 3
      )
      connection = test_connection do |stub|
        stub.post("/v1/embeddings") do
          [200, {"Content-Type" => "application/json"}, response.to_json]
        end
      end
      Maglev::Adapters::FaradayEmbedding.new(provider: provider, connection: connection)
    end

    def generation_adapter_for(response)
      provider = Maglev::ProviderConfiguration.new(
        url: "https://provider.example/v1",
        model: "generation-model"
      )
      connection = test_connection do |stub|
        stub.post("/v1/chat/completions") do
          [200, {"Content-Type" => "application/json"}, response.to_json]
        end
      end
      Maglev::Adapters::FaradayGeneration.new(provider: provider, connection: connection)
    end

    it "rejects invalid embedding response structures" do
      invalid_responses = [
        {},
        {"data" => []},
        {"data" => [{"embedding" => [0.1]}, {"embedding" => [0.2]}]},
        {"data" => [{}]},
        {"data" => [{"embedding" => "not-a-vector"}]},
        {"data" => [{"embedding" => []}]}
      ]

      invalid_responses.each do |response|
        expect { embedding_adapter_for(response).embed("text") }
          .to raise_error(Maglev::PermanentProviderError, /Embedding provider/)
      end
    end

    it "rejects invalid generation response structures" do
      invalid_responses = [
        {},
        {"choices" => []},
        {"choices" => [{}]},
        {"choices" => [{"message" => {}}]},
        {"choices" => [{"message" => {"content" => ["not", "text"]}}]},
        {"choices" => [{"message" => {"content" => ""}}]},
        {"choices" => [{"message" => {"content" => "   "}}]}
      ]

      invalid_responses.each do |response|
        expect { generation_adapter_for(response).generate("prompt") }
          .to raise_error(Maglev::PermanentProviderError, /Generation provider/)
      end
    end
  end
end
