# frozen_string_literal: true

require "base64"
require "json"

module Maglev
  module VectorStores
    module DocumentId
      module_function

      PREFIX = "maglev-v3-"

      def build(resource_identifier:, owner_type:, owner_id:, source_identity:, chunk_index:, index_version:, generation: nil)
        payload = [
          resource_identifier.to_s,
          owner_type.to_s,
          owner_id.to_s,
          source_identity.to_s,
          chunk_index.to_s,
          index_version.to_s
        ]
        payload << generation.to_s if generation
        "#{PREFIX}#{Base64.urlsafe_encode64(JSON.generate(payload), padding: false)}"
      end

      def parse(id)
        raise ArgumentError unless id.is_a?(String) && id.start_with?(PREFIX)

        payload = JSON.parse(Base64.urlsafe_decode64(id.delete_prefix(PREFIX)))
        unless payload.is_a?(Array) && [6, 7].include?(payload.length) &&
            payload.all? { |value| value.is_a?(String) && !value.empty? }
          raise ArgumentError
        end

        payload
      rescue JSON::ParserError, ArgumentError
        raise ArgumentError, "invalid Maglev document id"
      end
    end
  end
end
