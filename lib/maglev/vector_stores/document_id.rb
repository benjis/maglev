# frozen_string_literal: true

require "base64"

module Maglev
  module VectorStores
    module DocumentId
      module_function

      def build(owner_type:, owner_id:, source_identity:, chunk_index:)
        source = (source_identity == "snapshot") ? "snapshot" : "b64-#{Base64.urlsafe_encode64(source_identity, padding: false)}"
        "#{owner_type}:#{owner_id}:#{source}:#{chunk_index}"
      end

      def parse(id)
        parts = id.split(":")
        chunk_index = parts.pop
        source = parts.pop
        owner_id = parts.pop
        source_identity = source.start_with?("b64-") ? Base64.urlsafe_decode64(source.delete_prefix("b64-")) : source
        [parts.join(":"), owner_id, source_identity, chunk_index]
      rescue ArgumentError
        raise ArgumentError, "invalid Maglev document id"
      end
    end
  end
end
