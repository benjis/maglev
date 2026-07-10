# frozen_string_literal: true

module Maglev
  class Chunker
    def initialize(max_characters: Maglev.configuration.chunk_size)
      @max_characters = max_characters
    end

    def call(text)
      text.to_s.split(/\n{2,}/).flat_map { |part| split_part(part.strip) }.reject(&:empty?)
    end

    private

    def split_part(part)
      return [] if part.empty?
      return [part] if part.length <= @max_characters

      line_chunks = split_lines(part)
      return line_chunks if line_chunks.length > 1

      chunks = []
      current = +""

      part.split(/\s+/).each do |word|
        candidate = current.empty? ? word : "#{current} #{word}"
        if candidate.length > @max_characters && !current.empty?
          chunks << current
          current = word
        else
          current = candidate
        end
      end

      chunks << current unless current.empty?
      chunks
    end

    def split_lines(part)
      chunks = []
      current = +""

      part.lines(chomp: true).each do |line|
        candidate = current.empty? ? line : "#{current}\n#{line}"
        if candidate.length > @max_characters && !current.empty?
          chunks << current
          chunks.concat(split_part(line))
          current = +""
        else
          current = candidate
        end
      end

      chunks << current unless current.empty?
      chunks
    end
  end
end
