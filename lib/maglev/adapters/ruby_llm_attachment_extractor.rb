# frozen_string_literal: true

require_relative "../attachment_extractor"

module Maglev
  module Adapters
    class RubyLLMAttachmentExtractor < AttachmentExtractor
      def extract(blob, source_name:)
        require "ruby_llm"

        super
      end
    end
  end
end
