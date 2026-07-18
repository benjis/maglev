# frozen_string_literal: true

require "time"

module Maglev
  module Trace
    module_function

    def instrument(step, trace_id:, resource: nil, operation: nil)
      payload = compact_payload(trace_id: trace_id, route: :structured, resource: resource,
        operation: operation, status: :succeeded, timestamp: Time.now.utc.iso8601)
      error = nil
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      value = ActiveSupport::Notifications.instrument("maglev.structured.#{step}", payload) do
        yield(payload)
      rescue => caught
        error = caught
        payload[:status] = :failed
        payload[:error_code] = safe_error_code(caught)
        nil
      end
      payload[:duration_bucket] = duration_bucket(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
      emit_audit(step, payload.freeze)
      raise error if error

      value
    end

    def emit_audit(step, payload)
      sink = Maglev.configuration.audit_sink
      sink&.call(payload.merge(event: "maglev.structured.#{step}").freeze)
    rescue => error
      Maglev.configuration.logger&.warn("Maglev audit sink failed: #{error.class.name}")
    end

    def compact_payload(**values)
      values.compact
    end

    def safe_error_code(error)
      case error.class.name
      when "Maglev::QueryCompilationError" then :compilation_failed
      when "Maglev::StructuredExecutionError" then :execution_failed
      else :internal_error
      end
    end

    def duration_bucket(seconds)
      return :under_10ms if seconds < 0.01
      return :under_100ms if seconds < 0.1
      return :under_1s if seconds < 1

      :one_second_or_more
    end
  end
end
