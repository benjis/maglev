# frozen_string_literal: true

module Maglev
  class GenerationAdapter
    def generate(_prompt)
      raise NotImplementedError, "#{self.class.name} must implement #generate"
    end
  end
end
