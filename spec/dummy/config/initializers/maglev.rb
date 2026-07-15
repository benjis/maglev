# frozen_string_literal: true

module Dummy
  class EmbeddingAdapter
    def embed(text)
      checksum = text.each_byte.sum
      [checksum % 101, checksum % 103, checksum % 107].map { |value| value / 107.0 }
    end
  end

  class GenerationAdapter
    def generate(prompt)
      "Dummy grounded answer: #{prompt.lines.last.to_s.strip}"
    end
  end
end

Maglev.configure do |config|
  config.embedding_adapter = Dummy::EmbeddingAdapter.new
  config.embedding_dimensions = 3
  config.embedding_model = "dummy-deterministic-3d"
  config.generation_adapter = Dummy::GenerationAdapter.new
  config.generation_model = "dummy-deterministic"
end
