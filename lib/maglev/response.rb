# frozen_string_literal: true

module Maglev
  class Response
    attr_reader :text, :sources, :metadata

    def self.insufficient_context(question:)
      new(
        text: "Insufficient context to answer the question.",
        sources: [],
        metadata: {question: question, reason: "insufficient_context"}
      )
    end

    def initialize(text:, sources:, metadata: {})
      @text = text
      @sources = sources.freeze
      @metadata = metadata.freeze
      freeze
    end

    def to_s
      text
    end
  end
end
