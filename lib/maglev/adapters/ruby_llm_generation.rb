# frozen_string_literal: true

require_relative "../configuration"
require_relative "../generation_adapter"

module Maglev
  module Adapters
    class RubyLLMGeneration < GenerationAdapter
      def initialize(model: Maglev.configuration.generation_model)
        @model = model
      end

      def generate(prompt)
        require "ruby_llm"

        response = RubyLLM.chat(model: @model).ask(prompt)
        response.respond_to?(:content) ? response.content : response.to_s
      end
    end
  end
end
