# frozen_string_literal: true

module Maglev
  class EmbeddingAdapter
    def embed(_text)
      raise NotImplementedError, "#{self.class.name} must implement #embed"
    end
  end
end
