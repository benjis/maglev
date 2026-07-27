# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "openssl"
require "securerandom"

module Maglev
  class InMemoryContinuationStore
    def initialize
      @nonces = {}
      @mutex = Mutex.new
    end

    def register(nonce, expires_at)
      @mutex.synchronize { @nonces[nonce] = expires_at }
    end

    def consume(nonce, now)
      @mutex.synchronize do
        @nonces.delete_if { |_, expires_at| expires_at < now }
        !@nonces.delete(nonce).nil?
      end
    end
  end

  class ContinuationToken
    PURPOSE = "maglev-v0.3-clarification"

    def initialize(secret: Maglev.configuration.continuation_secret,
      clock: Maglev.configuration.continuation_clock,
      store: Maglev.configuration.continuation_store)
      unless secret.is_a?(String) && secret.bytesize >= 32
        raise ConfigurationError, "continuation_secret must contain at least 32 bytes"
      end
      unless store&.respond_to?(:register) && store.respond_to?(:consume)
        raise ConfigurationError, "continuation_store must atomically register and consume nonces"
      end

      @key = Digest::SHA256.digest(secret)
      @clock = clock
      @store = store
      @ttl = Maglev.configuration.continuation_ttl
      @max_bytes = Maglev.configuration.continuation_max_bytes
    end

    def issue(state)
      expires_at = @clock.call.to_i + @ttl
      nonce = SecureRandom.hex(16)
      payload = JSON.generate(
        "purpose" => PURPOSE,
        "expires_at" => expires_at,
        "nonce" => nonce,
        "state" => state
      )
      cipher = OpenSSL::Cipher.new("aes-256-gcm").encrypt
      cipher.key = @key
      iv = cipher.random_iv
      cipher.auth_data = PURPOSE
      encrypted = cipher.update(payload) + cipher.final
      token = Base64.urlsafe_encode64(iv + cipher.auth_tag + encrypted, padding: false)
      if token.bytesize > @max_bytes
        raise ConfigurationError, "continuation state exceeds the configured byte limit"
      end

      @store.register(nonce, expires_at)
      token.freeze
    end

    def consume(token, binding:)
      raise ArgumentError, "invalid continuation" unless token.is_a?(String)
      raise ArgumentError, "invalid continuation" if token.bytesize > @max_bytes

      raw = Base64.urlsafe_decode64(token)
      cipher = OpenSSL::Cipher.new("aes-256-gcm").decrypt
      cipher.key = @key
      cipher.iv = raw.byteslice(0, 12)
      cipher.auth_tag = raw.byteslice(12, 16)
      cipher.auth_data = PURPOSE
      payload = JSON.parse(cipher.update(raw.byteslice(28..)) + cipher.final)
      now = @clock.call.to_i
      unless payload["purpose"] == PURPOSE && payload["expires_at"].is_a?(Integer) &&
          payload["expires_at"] >= now && payload.dig("state", "binding") == binding
        raise ArgumentError, "invalid continuation"
      end
      result = block_given? ? yield(payload.fetch("state").freeze) : payload.fetch("state").freeze
      unless @store.consume(payload["nonce"], now)
        raise ArgumentError, "invalid continuation"
      end

      result
    rescue JSON::ParserError, OpenSSL::Cipher::CipherError, ArgumentError
      raise ArgumentError, "invalid continuation"
    end
  end
end
