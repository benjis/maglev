# frozen_string_literal: true

module Maglev
  class RoutingAdapter
    def classify(question:, capabilities:)
      raise NotImplementedError, "#{self.class.name} must implement #classify"
    end
  end

  class FakeRoutingAdapter < RoutingAdapter
    attr_reader :requests

    def initialize(outputs)
      @outputs = Array(outputs).dup
      @requests = []
    end

    def classify(**request)
      @requests << request.freeze
      raise PermanentProviderError, "Fake router has no remaining output" if @outputs.empty?

      @outputs.shift
    end
  end
end
