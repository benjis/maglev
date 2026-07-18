# frozen_string_literal: true

require "json"

module Maglev
  class StructuredEvidenceBuilder
    def initialize(plan:, relation:, resource:, rows:, bytes:)
      raise ArgumentError, "evidence rows must be positive" unless rows.is_a?(Integer) && rows.positive?
      raise ArgumentError, "evidence bytes must be positive" unless bytes.is_a?(Integer) && bytes.positive?

      @plan = plan
      @relation = relation
      @resource = resource
      @rows = rows
      @bytes = bytes
    end

    def build
      @filters = @plan.ir.filters.map(&:to_h)
      @date_ranges = @filters.select { |filter| filter["operator"] == "between" }
      StructuredEvidence.new(filters: @filters,
        date_ranges: @date_ranges,
        loader: method(:load_records))
    end

    private

    def load_records
      Trace.instrument(:execution, trace_id: @plan.trace_id, resource: @plan.resource,
        operation: @plan.ir.operation) do |payload|
        query_limit = [@relation.limit_value || @rows + 1, @rows + 1].min
        fields = @resource.fields.map(&:name)
        projected = @relation.limit(query_limit).to_a.map do |record|
          fields.to_h { |field| [field, record.public_send(field)] }
        end
        records = []
        projected.first(@rows).each do |record|
          candidate = [*records, record]
          break if serialized_size(candidate, truncated: projected.length > candidate.length) > @bytes

          records << record
        end
        truncated = projected.length > records.length
        used_bytes = serialized_size(records, truncated: truncated)
        payload[:row_count] = records.length
        payload[:evidence_bytes] = used_bytes
        [records, records.length, truncated]
      end
    end

    def serialized_size(records, truncated:)
      JSON.generate("records" => records, "scalar" => nil, "filters" => @filters,
        "date_ranges" => @date_ranges, "count" => records.length, "truncated" => truncated).bytesize
    end
  end
end
