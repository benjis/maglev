# frozen_string_literal: true

module Maglev
  class HybridCandidateSet
    DEFAULT_LIMIT = 100

    attr_reader :model_class, :ids, :tenant_id, :trace_id

    def self.from_relation(relation:, model_class:, trace_id:, tenant_id: nil, limit: DEFAULT_LIMIT)
      unless defined?(ActiveRecord::Relation) && relation.is_a?(ActiveRecord::Relation) &&
          relation.klass == model_class
        raise ConfigurationError, "candidate relation must match the requested model"
      end

      query_limit = [relation.limit_value || limit + 1, limit + 1].min
      ids = relation.limit(query_limit).pluck(model_class.primary_key)
      new(model_class: model_class, ids: ids, tenant_id: tenant_id, trace_id: trace_id, limit: limit)
    end

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
