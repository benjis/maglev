# frozen_string_literal: true

require "json"
require_relative "trace"

module Maglev
  class GroundingError < Error
  end

  class StructuredAnswerComposer
    def initialize(generation_adapter: nil)
      @generation_adapter = generation_adapter
    end

    def compose(result)
      unless result.is_a?(StructuredResult)
        raise GroundingError, "A structured result is required"
      end

      Trace.instrument(:composition, trace_id: result.trace_id,
        resource: result.plan.resource, operation: result.plan.ir&.operation) do
        (@generation_adapter && result.status == :succeeded) ? generate(result) : result.render
      end
    end

    private

    def generate(result)
      evidence = {
        "records" => result.evidence.records,
        "scalar" => result.evidence.scalar,
        "filters" => result.evidence.filters,
        "date_ranges" => result.evidence.date_ranges,
        "count" => result.evidence.count,
        "truncated" => result.evidence.truncated
      }.freeze
      output = @generation_adapter.generate(JSON.generate(evidence))
      unless output.is_a?(Hash) && output.keys == ["claim_paths"] && output["claim_paths"].is_a?(Array) &&
          output["claim_paths"].any?
        raise GroundingError, "Structured generation must return claim paths"
      end

      output.fetch("claim_paths").map { |path| render_claim(evidence, path) }.join(" ").freeze
    end

    def render_claim(evidence, path)
      valid_segments = path.is_a?(Array) && path.all? { |segment| [String, Integer].any? { |type| segment.is_a?(type) } }
      unless valid_segments && path.length.between?(1, 3)
        raise GroundingError, "Generated claim is absent from structured evidence"
      end

      value = path.reduce(evidence) do |current, segment|
        if current.is_a?(Hash) && segment.is_a?(String) && current.key?(segment)
          current.fetch(segment)
        elsif current.is_a?(Array) && segment.is_a?(Integer) && segment.between?(0, current.length - 1)
          current.fetch(segment)
        else
          raise GroundingError, "Generated claim is absent from structured evidence"
        end
      end
      raise GroundingError, "Generated claim must identify one scalar evidence value" if value.is_a?(Hash) || value.is_a?(Array)

      label = path.last.to_s.tr("_", " ").capitalize
      "#{label}: #{value}."
    end
  end
end
