# frozen_string_literal: true

module Maglev
  class SearchResult
    attr_reader :owner, :content, :source, :distance, :chunk_index, :source_identity, :source_type, :score

    def initialize(owner:, content:, source:, distance:, chunk_index: nil, source_identity: nil, source_type: nil, score: nil)
      @owner = owner
      @content = content
      @source = source
      @distance = distance
      @chunk_index = chunk_index
      @source_identity = source_identity || source
      @source_type = (source_type || :snapshot).to_sym
      @score = score
      freeze
    end

    def similarity
      return score.clamp(0.0, 1.0) unless score.nil?
      return nil if distance.nil?

      (1.0 - distance.to_f).clamp(0.0, 1.0)
    end
  end
end
