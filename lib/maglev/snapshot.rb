# frozen_string_literal: true

module Maglev
  class Snapshot
    def initialize(lines)
      @text = lines.join("\n").freeze
      freeze
    end

    def to_s
      @text
    end
  end
end
