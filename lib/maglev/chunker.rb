# frozen_string_literal: true

module Maglev
  class Chunker
    ALGORITHM_VERSION = "1"

    def initialize(max_characters: Maglev.configuration.chunk_size)
      unless max_characters.is_a?(Integer) && max_characters.positive?
        raise ArgumentError, "max_characters must be positive"
      end

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
      return line_chunks.flat_map { |chunk| hard_split(chunk) } if line_chunks.length > 1

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
      chunks.flat_map { |chunk| hard_split(chunk) }
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

    def hard_split(text)
      chunks = []
      current = +""

      text.scan(/\X/).each do |grapheme|
        if grapheme.length > @max_characters
          chunks << current unless current.empty?
          chunks.concat(grapheme.chars.each_slice(@max_characters).map(&:join))
          current = +""
        elsif current.length + grapheme.length > @max_characters
          chunks << current
          current = +grapheme
        else
          current << grapheme
        end
      end

      chunks << current unless current.empty?
      chunks
    end
  end
end
