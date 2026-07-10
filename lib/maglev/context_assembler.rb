# frozen_string_literal: true

module Maglev
  class ContextAssembler
    Context = Struct.new(:text, :sources, :metadata)

    def initialize(max_characters: nil, per_owner_characters: nil)
      max_characters ||= Maglev.configuration.context_max_characters
      per_owner_characters ||= Maglev.configuration.context_per_owner_characters
      @max_characters = max_characters
      @per_owner_characters = per_owner_characters
    end

    def assemble(results)
      entries = []
      sources = []
      owner_characters = Hash.new(0)
      text_length = 0

      sorted_results(results).each do |result|
        marker = "[S#{sources.length + 1}]"
        content = redacted_content(result)
        entry = entry_for(result, marker, content)
        owner_key = owner_key(result.owner)

        next if owner_characters[owner_key] + content.length > @per_owner_characters
        next if text_length + separator_length(entries) + entry.length > @max_characters

        separator_length = separator_length(entries)
        entries << entry
        text_length += separator_length + entry.length
        owner_characters[owner_key] += content.length
        sources << source_for(result, marker, content)
      end

      text = entries.join("\n")
      Context.new(
        text: text,
        sources: sources,
        metadata: {context_characters: text.length, source_count: sources.length}
      )
    end

    private

    def sorted_results(results)
      results.sort_by { |result| result.distance || Float::INFINITY }
    end

    def entry_for(result, marker, content)
      "#{marker} #{owner_label(result.owner)} chunk #{result.chunk_index} source: #{result.source}\n#{content}"
    end

    def source_for(result, marker, content)
      {
        marker: marker,
        owner_type: owner_type(result.owner),
        owner_id: owner_id(result.owner),
        source: result.source,
        chunk_index: result.chunk_index,
        content: content,
        distance: result.distance,
        similarity: result.similarity
      }
    end

    def redacted_content(result)
      redactor = Maglev.configuration.source_redactor
      return result.content unless redactor

      redactor.call(result.content, result)
    end

    def separator_length(entries)
      entries.empty? ? 0 : 1
    end

    def owner_key(owner)
      [owner_type(owner), owner_id(owner), owner.object_id]
    end

    def owner_label(owner)
      "#{owner_type(owner)}##{owner_id(owner)}"
    end

    def owner_type(owner)
      owner.class.name
    end

    def owner_id(owner)
      owner.respond_to?(:id) ? owner.id : owner
    end
  end
end
