# frozen_string_literal: true

require_relative "source_fragment"

module Maglev
  class SourceExtractor
    def call(snapshot)
      related = {}
      snapshot.to_s.lines(chomp: true).drop(1).filter_map do |line|
        if (match = line.match(/\A(.+\[\d+\]) ([A-Za-z0-9_:]+)#([^ ]+)\z/))
          related[match[1]] = [match[2], match[3]]
          next
        end
        next unless line.include?(": ")

        path = line.split(": ", 2).first
        identity = related_identity(path, related) || path
        next if identity.nil? || identity.empty?

        SourceFragment.new(identity: identity, type: source_type(identity), content: line)
      end.freeze
    end

    private

    def related_identity(path, related)
      prefix, record = related.find { |candidate, _identity| path.start_with?("#{candidate}.") }
      return unless record

      model, id = record
      "related:#{model}:#{id}:#{path.delete_prefix("#{prefix}.")}"
    end

    def source_type(identity)
      return :attachment if identity.include?("[blob:")
      return :rich_text if identity.start_with?("rich_text.")
      return :related_record if identity.start_with?("related:") || identity.include?("[") || identity.include?(".")
      return :tag if identity == "tags"

      :attribute
    end
  end
end
