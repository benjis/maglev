# frozen_string_literal: true

require "json"

module Maglev
  module PlannerEvaluation
    module_function

    def score(cases)
      results = cases.map { |test_case| score_case(test_case) }.freeze
      passed = results.count { |result| result[:passed] }
      total = results.length
      {total: total, passed: passed, failed: total - passed,
       score: total.zero? ? 0.0 : passed.fdiv(total), cases: results}.freeze
    end

    def load(path)
      corpus = JSON.parse(File.read(path))
      raise ArgumentError, "unsupported planner evaluation corpus" unless corpus["version"] == 1 && corpus["cases"].is_a?(Array)

      corpus
    end

    def score_case(test_case)
      expected = test_case.fetch("expected")
      actual = test_case.fetch("actual")
      failure_class = if expected["status"] != actual["status"]
        :status_mismatch
      elsif expected["status"] == "ready" && canonical(expected["ir"]) != canonical(actual["ir"])
        :ir_mismatch
      end
      {id: test_case.fetch("id"), passed: failure_class.nil?, failure_class: failure_class}.freeze
    end
    private_class_method :score_case

    def canonical(value, parent = nil)
      case value
      when Hash
        value.keys.sort.to_h { |key| [key, canonical(value[key], key)] }
      when Array
        items = value.map { |item| canonical(item) }
        %w[filters joins].include?(parent) ? items.sort_by { |item| JSON.generate(item) } : items
      else
        value
      end
    end
    private_class_method :canonical
  end
end
