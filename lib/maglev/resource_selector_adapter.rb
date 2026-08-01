# frozen_string_literal: true

module Maglev
  class ResourceSelectorAdapter
    def select(question:, catalog:, semantic_context: nil)
      raise NotImplementedError, "#{self.class.name} must implement #select"
    end
  end

  class FakeResourceSelectorAdapter < ResourceSelectorAdapter
    attr_reader :requests

    def initialize(outputs)
      @outputs = Array(outputs).dup
      @requests = []
    end

    def select(**request)
      @requests << request.freeze
      raise PermanentProviderError, "Fake resource selector has no remaining output" if @outputs.empty?

      @outputs.shift
    end
  end
end
