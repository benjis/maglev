# frozen_string_literal: true

module Maglev
  class HybridEvidence
    attr_reader :provenance, :value

    def initialize(provenance:, value:)
      raise ArgumentError, "invalid hybrid evidence provenance" unless %i[structured rag].include?(provenance)

      @provenance = provenance
      @value = value
      freeze
    end
  end

  class HybridAnswer
    attr_reader :records, :claims

    def initialize(records:, claims: [])
      @records = records.freeze
      @claims = claims.freeze
      freeze
    end
  end
end
