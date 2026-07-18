# frozen_string_literal: true

module Maglev
  class RetrievalOutcome
    attr_reader :results, :minimum_similarity, :examined_count,
      :accepted_count, :rejected_count, :best_similarity

    def initialize(results:, minimum_similarity:, examined_count:,
      accepted_count:, rejected_count:, best_similarity:)
      @results = results.freeze
      @minimum_similarity = minimum_similarity
      @examined_count = examined_count
      @accepted_count = accepted_count
      @rejected_count = rejected_count
      @best_similarity = best_similarity
      freeze
    end

    def empty_reason
      return nil if @results.any?

      if @examined_count.positive?
        :threshold_rejected
      else
        :no_candidates
      end
    end

    def threshold_rejected?
      empty_reason == :threshold_rejected
    end

    def no_candidates?
      empty_reason == :no_candidates
    end

    def metadata
      {
        minimum_similarity: minimum_similarity,
        examined_count: examined_count,
        accepted_count: accepted_count,
        rejected_count: rejected_count,
        best_similarity: best_similarity
      }.freeze
    end
  end
end
