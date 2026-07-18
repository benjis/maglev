# frozen_string_literal: true

require "cgi"

require_relative "attachment_extractor"
require_relative "relation_order"
require_relative "snapshot"
require_relative "snapshot_budget"

module Maglev
  class SnapshotBuilder
    def initialize(record, config, path: nil, visited: nil, attachment_extractor: nil, remaining_depth: Maglev.configuration.max_relation_depth, budget: nil)
      @record = record
      @config = config
      @path = path
      @visited = visited || {}
      @attachment_extractor = attachment_extractor || Maglev.configuration.attachment_extractor || AttachmentExtractor.new
      @remaining_depth = remaining_depth
      @budget = budget || SnapshotBudget.new
    end

    def build
      return Snapshot.new([]) if visited?

      mark_visited
      raw_lines = lines
      text = raw_lines.join("\n")
      text = @budget.truncate(text, kind: :whole_snapshot, path: "snapshot") unless @path
      Snapshot.new(text.lines(chomp: true), metadata: @budget.metadata)
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
        next if value.nil?

        text = @budget.truncate(value, kind: :attribute, path: attribute_path(attribute))
        "#{attribute_path(attribute)}: #{text}"
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
          child = SnapshotBuilder.new(
            related_record,
            related_record.class.maglev_config,
            path: relation_path,
            visited: @visited,
            attachment_extractor: @attachment_extractor,
            remaining_depth: remaining_depth,
            budget: @budget
          ).build.to_s
          @budget.truncate(child, kind: :related_record, path: relation_path).split("\n")
        end
      end
    end

    def attachment_lines
      @config.attached_sources.flat_map do |source|
        attachment_blobs(source.name).flat_map do |blob|
          document = extract_attachment(source.name, blob)
          if document.extracted?
            path = document.source_identifier
            text = @budget.truncate(document.text, kind: :attachment, path: path)
            ["#{path}.text: #{text}"]
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
        path = rich_text_identifier(source.name)
        text = @budget.truncate(text, kind: :rich_text, path: path) unless text.nil?
        "#{path}.text: #{text}" unless text.nil? || text.empty?
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
      elsif loaded_collection_proxy?(value)
        [relation.order ? ordered_array(value.target, relation) : ordered_loaded_records(value), true]
      elsif active_record_relation?(value)
        [ordered_relation(value, relation).limit(relation.limit).to_a, true]
      elsif value.respond_to?(:to_ary)
        [ordered_array(value.to_ary, relation), true]
      else
        [[value], false]
      end

      [records.first(relation.limit), collection]
    end

    def active_record_relation?(value)
      (defined?(ActiveRecord::Relation) && value.is_a?(ActiveRecord::Relation)) ||
        (defined?(ActiveRecord::Associations::CollectionProxy) && value.is_a?(ActiveRecord::Associations::CollectionProxy))
    end

    def loaded_collection_proxy?(value)
      defined?(ActiveRecord::Associations::CollectionProxy) &&
        value.is_a?(ActiveRecord::Associations::CollectionProxy) && value.loaded?
    end

    def ordered_relation(value, relation)
      if relation.order
        order = effective_order(relation.order, value.klass)
        return value.reorder(order)
      end
      return value unless value.order_values.empty?

      primary_key = value.klass.primary_key
      primary_key ? value.order(primary_key => :asc) : value
    end

    def effective_order(order, klass)
      RelationOrder.with_primary_key(order, klass)
    end

    def ordered_array(records, relation)
      return records unless relation.order

      order = relation.order
      records.sort do |left, right|
        comparison = order.lazy.map do |attribute, direction|
          value = compare_values(left.public_send(attribute), right.public_send(attribute))
          (direction == :desc) ? -value : value
        end.find { |value| !value.zero? } || 0
        comparison.zero? ? compare_values(record_id_for(left), record_id_for(right)) : comparison
      end
    end

    def compare_values(left, right)
      return 0 if left == right
      return -1 if left.nil?
      return 1 if right.nil?

      left <=> right
    end

    def record_id_for(record)
      record.respond_to?(:id) ? record.id : record.object_id
    end

    def ordered_loaded_records(value)
      records = value.to_ary
      return records unless value.order_values.empty?

      primary_key = value.klass.primary_key
      return records unless primary_key

      persisted, unsaved = records.partition(&:persisted?)
      persisted.sort_by { |record| record.public_send(primary_key) } + unsaved
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
