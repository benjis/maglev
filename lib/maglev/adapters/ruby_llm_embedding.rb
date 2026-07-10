# frozen_string_literal: true

require_relative "../embedding_adapter"

module Maglev
  module Adapters
    class RubyLLMEmbedding < EmbeddingAdapter
      def initialize(model: Maglev.configuration.embedding_model, dimensions: Maglev.configuration.embedding_dimensions)
        @model = model
        @dimensions = dimensions
      end

      def embed(text)
        require "ruby_llm"

        result = RubyLLM.embed(text, model: @model, dimensions: @dimensions)
        result.vectors.first.is_a?(Array) ? result.vectors.first : result.vectors
      end
    end
  end
end
