# frozen_string_literal: true

require_relative "dependency_graph"

module Maglev
  class ContentSourceGraph
    class << self
      def register(config)
        register_active_storage if config.attached_sources.any?
        register_action_text if config.rich_text_sources.any?
      end

      def reindex_attachment_owner(attachment)
        record = attachment.record
        return unless record && declared_attached?(record.class, attachment.name)

        DependencyGraph.reindex_record_and_dependents_for(record) if record.id
      end

      def reindex_rich_text_owner(rich_text)
        record = rich_text.record
        return unless record && declared_rich_text?(record.class, rich_text.name)

        DependencyGraph.reindex_record_and_dependents_for(record) if record.id
      end

      private

      def register_active_storage
        return unless defined?(ActiveStorage::Attachment)
        return if ActiveStorage::Attachment.method_defined?(:maglev_reindex_attachment_owner)

        ActiveStorage::Attachment.class_eval do
          def maglev_reindex_attachment_owner
            Maglev::ContentSourceGraph.reindex_attachment_owner(self)
          end

          after_commit :maglev_reindex_attachment_owner, on: %i[create destroy]
        end
      end

      def register_action_text
        return unless defined?(ActionText::RichText)
        return if ActionText::RichText.method_defined?(:maglev_reindex_rich_text_owner)

        ActionText::RichText.class_eval do
          def maglev_reindex_rich_text_owner
            Maglev::ContentSourceGraph.reindex_rich_text_owner(self)
          end

          after_commit :maglev_reindex_rich_text_owner, on: %i[create update destroy]
        end
      end

      def declared_attached?(klass, name)
        config = klass.respond_to?(:maglev_config) ? klass.maglev_config : nil
        config&.attached_sources&.any? { |source| source.name == name.to_s }
      end

      def declared_rich_text?(klass, name)
        config = klass.respond_to?(:maglev_config) ? klass.maglev_config : nil
        config&.rich_text_sources&.any? { |source| source.name == name.to_s }
      end
    end
  end
end
