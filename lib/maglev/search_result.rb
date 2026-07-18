# frozen_string_literal: true

module Maglev
  class SearchResult
    attr_reader :owner, :content, :source, :distance, :chunk_index

    def initialize(owner:, content:, source:, distance:, chunk_index: nil)
      @owner = owner
      @content = content
      @source = source
      @distance = distance
      @chunk_index = chunk_index
      freeze
    end

    def similarity
      return nil if distance.nil?

      (1.0 - distance.to_f).clamp(0.0, 1.0)
    end
  end
end
