# frozen_string_literal: true

module Maglev
  class HybridCandidateSet
    DEFAULT_LIMIT = 100

    attr_reader :model_class, :ids, :tenant_id, :trace_id

    def initialize(model_class:, ids:, tenant_id:, trace_id:, limit: DEFAULT_LIMIT)
      raise ArgumentError, "candidate limit must be a positive Integer" unless limit.is_a?(Integer) && limit.positive?
      raise ConfigurationError, "hybrid candidate set exceeds #{limit} ids" if ids.size > limit

      primary_key = model_class.primary_key
      type = model_class.type_for_attribute(primary_key)
      cast_ids = ids.map { |id| type.cast(id) }
      raise ConfigurationError, "hybrid candidate set contains an invalid primary key" if cast_ids.any?(&:nil?)

      @model_class = model_class
      @ids = cast_ids.uniq.freeze
      @tenant_id = tenant_id&.to_s&.freeze
      @trace_id = trace_id.to_s.freeze
      freeze
    end
  end
end
