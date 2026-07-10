# frozen_string_literal: true

module Maglev
  class ExtractedDocument
    attr_reader :source_identifier, :text, :metadata, :status

    def self.extracted(source_identifier:, text:, metadata: {})
      new(source_identifier: source_identifier, text: text, metadata: metadata, status: :extracted)
    end

    def self.skipped(source_identifier:, reason:, metadata: {})
      new(
        source_identifier: source_identifier,
        text: "",
        metadata: metadata.merge(reason: reason),
        status: :skipped
      )
    end

    def initialize(source_identifier:, text:, metadata:, status:)
      @source_identifier = source_identifier
      @text = text
      @metadata = metadata.freeze
      @status = status
      freeze
    end

    def extracted?
      status == :extracted
    end

    def skipped?
      status == :skipped
    end
  end
end
