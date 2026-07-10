# frozen_string_literal: true

require "cgi"

require_relative "configuration"
require_relative "extracted_document"

module Maglev
  class AttachmentExtractor
    def initialize(allowed_content_types: Maglev.configuration.attachment_allowed_content_types,
      max_bytes: Maglev.configuration.attachment_max_bytes,
      max_characters: Maglev.configuration.attachment_max_characters)
      @allowed_content_types = allowed_content_types
      @max_bytes = max_bytes
      @max_characters = max_characters
    end

    def extract(blob, source_name:)
      source_identifier = source_identifier(source_name, blob)
      metadata = metadata_for(blob)
      return skipped(source_identifier, "unsupported_content_type", metadata) unless allowed?(blob)
      return skipped(source_identifier, "size_limit", metadata) if too_large?(blob)

      text = extract_text(blob)
      text, truncated = truncate(text)
      ExtractedDocument.extracted(
        source_identifier: source_identifier,
        text: text,
        metadata: metadata.merge(strategy: "deterministic", truncated: truncated)
      )
    end

    private

    def source_identifier(source_name, blob)
      "#{source_name}[blob:#{blob_identifier(blob)}]"
    end

    def blob_identifier(blob)
      if blob.respond_to?(:id) && blob.id
        blob.id
      elsif blob.respond_to?(:key) && blob.key
        blob.key
      else
        filename(blob)
      end
    end

    def metadata_for(blob)
      {
        filename: filename(blob),
        content_type: content_type(blob),
        byte_size: byte_size(blob)
      }
    end

    def filename(blob)
      blob.respond_to?(:filename) ? blob.filename.to_s : "unknown"
    end

    def content_type(blob)
      blob.respond_to?(:content_type) ? blob.content_type.to_s : ""
    end

    def byte_size(blob)
      blob.respond_to?(:byte_size) ? blob.byte_size.to_i : 0
    end

    def allowed?(blob)
      @allowed_content_types.include?(content_type(blob))
    end

    def too_large?(blob)
      byte_size(blob) > @max_bytes
    end

    def extract_text(blob)
      text = blob.download.to_s
      html?(blob) ? sanitize_html(text) : text
    end

    def html?(blob)
      %w[text/html application/xhtml+xml].include?(content_type(blob))
    end

    def sanitize_html(html)
      without_scripts = html.gsub(%r{<script\b[^>]*>.*?</script>}im, " ")
        .gsub(%r{<style\b[^>]*>.*?</style>}im, " ")
      CGI.unescapeHTML(without_scripts.gsub(/<[^>]+>/, " ").squeeze(" ").strip)
    end

    def truncate(text)
      return [text, false] if text.length <= @max_characters

      [text[0, @max_characters], true]
    end

    def skipped(source_identifier, reason, metadata)
      ExtractedDocument.skipped(
        source_identifier: source_identifier,
        reason: reason,
        metadata: metadata.merge(strategy: "deterministic")
      )
    end
  end
end
