# frozen_string_literal: true

module Maglev
  class RetrievalResult
    attr_reader :query, :considered, :selected, :rejected, :context, :budgets, :reasons, :timings, :trace_id

    def initialize(query:, considered:, selected:, rejected:, context:, budgets:, reasons:, timings:, trace_id:)
      @query = query.to_s.freeze
      @considered = considered.freeze
      @selected = selected.freeze
      @rejected = rejected.map { |item| item.freeze }.freeze
      @context = context.to_s.freeze
      @budgets = budgets.freeze
      @reasons = reasons.freeze
      @timings = timings.freeze
      @trace_id = trace_id.to_s.freeze
      freeze
    end

    def metadata
      {trace_id: trace_id, considered_count: considered.size, selected_count: selected.size,
       rejected_count: rejected.size, budgets: budgets, reasons: reasons, timings: timings}.freeze
    end
  end
end
