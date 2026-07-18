# frozen_string_literal: true

module Maglev
  class SnapshotBudget
    LIMIT_METHODS = {
      attribute: :snapshot_attribute_max_characters,
      rich_text: :snapshot_attribute_max_characters,
      attachment: :snapshot_attribute_max_characters,
      related_record: :snapshot_related_record_max_characters,
      whole_snapshot: :snapshot_max_characters
    }.freeze

    def initialize(configuration: Maglev.configuration)
      @limits = {
        attribute_characters: configuration.snapshot_attribute_max_characters,
        related_record_characters: configuration.snapshot_related_record_max_characters,
        snapshot_characters: configuration.snapshot_max_characters,
        chunks: configuration.snapshot_max_chunks
      }.freeze
      @configuration = configuration
      @sources = []
    end

    def truncate(text, kind:, path:)
      value = text.to_s
      limit = @configuration.public_send(LIMIT_METHODS.fetch(kind))
      return value if value.length <= limit

      @sources << {
        kind: kind,
        path: path,
        original_characters: value.length,
        retained_characters: limit
      }.freeze
      value[0, limit]
    end

    def record_chunk_truncation(original:, retained:, path: "snapshot.chunks")
      return if original <= retained

      @sources << {
        kind: :chunks,
        path: path,
        original_chunks: original,
        retained_chunks: retained
      }.freeze
    end

    def metadata
      {
        truncated: @sources.any?,
        limits: @limits,
        sources: @sources.dup.freeze
      }.freeze
    end
  end
end
