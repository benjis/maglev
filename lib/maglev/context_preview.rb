# frozen_string_literal: true

module Maglev
  class ContextPreview
    attr_reader :text, :metadata

    def initialize(text:, metadata:)
      @text = text
      @metadata = metadata.freeze
      freeze
    end
  end
end
