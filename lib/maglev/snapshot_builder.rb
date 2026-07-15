# frozen_string_literal: true

require "cgi"

require_relative "attachment_extractor"
require_relative "snapshot"

module Maglev
  class SnapshotBuilder
    def initialize(record, config, path: nil, visited: nil, attachment_extractor: nil, remaining_depth: Maglev.configuration.max_relation_depth)
      @record = record
      @config = config
      @path = path
      @visited = visited || {}
      @attachment_extractor = attachment_extractor || Maglev.configuration.attachment_extractor || AttachmentExtractor.new
      @remaining_depth = remaining_depth
    end

    def build
      return Snapshot.new([]) if visited?

      mark_visited
      Snapshot.new(lines)
    end

    private

    def lines
      [
        header,
        *attribute_lines,
        *tag_lines,
        *attachment_lines,
        *rich_text_lines,
        *relation_lines
      ]
    end

    def header
      label = "#{@record.class.name}##{record_id}"
      @path ? "#{@path} #{label}" : label
    end

    def record_id
      id = @record.respond_to?(:id) ? @record.id : nil
      id.nil? ? "new_record" : id
    end

    def attribute_lines
      @config.exposed_attributes.filter_map do |attribute|
        value = @record.public_send(attribute)
        "#{attribute_path(attribute)}: #{value}" unless value.nil?
      end
    end

    def tag_lines
      return [] if @config.tags.empty?

      ["tags: #{@config.tags.join(", ")}"]
    end

    def relation_lines
      return [] unless @remaining_depth.positive?

      @config.relations.flat_map do |relation|
        remaining_depth = [@remaining_depth, relation.depth].min - 1
        relation_records, collection = relation_records(relation)
        relation_records.each_with_index.flat_map do |related_record, index|
          relation_path = path_for(relation, index, collection: collection)
          SnapshotBuilder.new(
            related_record,
            related_record.class.maglev_config,
            path: relation_path,
            visited: @visited,
            attachment_extractor: @attachment_extractor,
            remaining_depth: remaining_depth
          ).build.to_s.split("\n")
        end
      end
    end

    def attachment_lines
      @config.attached_sources.flat_map do |source|
        attachment_blobs(source.name).flat_map do |blob|
          document = extract_attachment(source.name, blob)
          if document.extracted?
            ["#{document.source_identifier}.text: #{document.text}"]
          else
            ["#{document.source_identifier}.skipped: #{document.metadata[:reason]}"]
          end
        end
      end
    end

    def attachment_blobs(source_name)
      value = @record.public_send(source_name)
      attachments = if value.respond_to?(:attachments)
        value.attachments.to_a
      elsif value.respond_to?(:attachment)
        [value.attachment].compact
      elsif value.respond_to?(:blob)
        [value]
      elsif value.respond_to?(:to_ary)
        value.to_ary
      else
        [value].compact
      end

      attachments.map { |attachment| attachment.respond_to?(:blob) ? attachment.blob : attachment }
    end

    def extract_attachment(source_name, blob)
      @attachment_extractor.extract(blob, source_name: source_name)
    rescue
      ExtractedDocument.skipped(
        source_identifier: "#{source_name}[blob:#{blob_identifier(blob)}]",
        reason: "extraction_failed",
        metadata: {
          filename: blob.respond_to?(:filename) ? blob.filename.to_s : "unknown",
          content_type: blob.respond_to?(:content_type) ? blob.content_type.to_s : nil
        }
      )
    end

    def rich_text_lines
      @config.rich_text_sources.filter_map do |source|
        text = rich_text_value(source.name)
        "#{rich_text_identifier(source.name)}.text: #{text}" unless text.nil? || text.empty?
      end
    end

    def rich_text_value(source_name)
      value = @record.public_send(source_name)
      text = if value.respond_to?(:body) && value.body.respond_to?(:to_plain_text)
        value.body.to_plain_text
      elsif value.respond_to?(:to_plain_text)
        value.to_plain_text
      elsif value.respond_to?(:body) && value.body.respond_to?(:to_html)
        sanitize_html(value.body.to_html.to_s)
      else
        sanitize_html(value.to_s)
      end
      text.squeeze(" ").strip
    end

    def rich_text_identifier(source_name)
      "rich_text.#{source_name}"
    end

    def blob_identifier(blob)
      if blob.respond_to?(:id) && blob.id
        blob.id
      elsif blob.respond_to?(:key) && blob.key
        blob.key
      elsif blob.respond_to?(:filename)
        blob.filename.to_s
      else
        "unknown"
      end
    end

    def sanitize_html(html)
      without_scripts = html.gsub(%r{<script\b[^>]*>.*?</script>}im, " ")
        .gsub(%r{<style\b[^>]*>.*?</style>}im, " ")
      CGI.unescapeHTML(without_scripts.gsub(/<[^>]+>/, " ").squeeze(" ").strip)
    end

    def relation_records(relation)
      value = @record.public_send(relation.name)
      records, collection = if value.nil?
        [[], false]
      elsif value.respond_to?(:to_ary)
        [value.to_ary, true]
      elsif value.respond_to?(:limit)
        [value.limit(relation.limit).to_a, true]
      else
        [[value], false]
      end

      [records.first(relation.limit), collection]
    end

    def path_for(relation, index, collection:)
      segment = collection ? "#{relation.name}[#{index}]" : relation.name
      @path ? "#{@path}.#{segment}" : segment
    end

    def attribute_path(attribute)
      @path ? "#{@path}.#{attribute}" : attribute
    end

    def visited?
      @visited.key?(record_key)
    end

    def mark_visited
      @visited[record_key] = true
    end

    def record_key
      [@record.class.name, record_id]
    end
  end
end
