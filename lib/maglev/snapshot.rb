# frozen_string_literal: true

module Maglev
  class Snapshot
    attr_reader :metadata

    def initialize(lines, metadata: {})
      @text = lines.join("\n").freeze
      @metadata = deep_freeze(metadata)
      freeze
    end

    def to_s
      @text
    end

    def truncated?
      @metadata[:truncated] == true
    end

    private

    def deep_freeze(value)
      case value
      when Hash
        value.to_h { |key, item| [key, deep_freeze(item)] }.freeze
      when Array
        value.map { |item| deep_freeze(item) }.freeze
      else
        value.freeze
      end
    end
  end
end
