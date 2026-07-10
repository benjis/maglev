# frozen_string_literal: true

require "active_support/concern"

require_relative "answerer"
require_relative "content_source_graph"
require_relative "context_preview"
require_relative "dependency_graph"
require_relative "knowledge_config"
require_relative "indexer"
require_relative "reindex_job"
require_relative "retriever"
require_relative "schema_compiler"
require_relative "snapshot_builder"

module Maglev
  module ActiveRecordExtension
    extend ActiveSupport::Concern

    class_methods do
      def has_knowledge(&block)
        @maglev_config = KnowledgeConfig.build(self, &block)
        @maglev_schema = SchemaCompiler.new(@maglev_config).compile if @maglev_config.relations.any?
        DependencyGraph.register(@maglev_schema) if @maglev_schema
        ContentSourceGraph.register(@maglev_config)
        register_maglev_callbacks
      end

      def maglev_config
        if instance_variable_defined?(:@maglev_config)
          @maglev_config
        elsif superclass.respond_to?(:maglev_config)
          superclass.maglev_config
        end
      end

      def search(query, limit: 10, user: nil)
        Retriever.new(self).search(query, limit: limit, user: user)
      end

      def maglev_schema
        config = maglev_config
        {
          model: name,
          exposed_attributes: config&.exposed_attributes || [],
          relations: config&.relations&.map(&:name) || [],
          attached_sources: config&.attached_sources&.map(&:name) || [],
          rich_text_sources: config&.rich_text_sources&.map(&:name) || []
        }
      end

      def ask(question, limit: 10, user: nil)
        user ? Answerer.new(self).ask(question, limit: limit, user: user) : Answerer.new(self).ask(question, limit: limit)
      end

      private

      def register_maglev_callbacks
        return if instance_variable_defined?(:@maglev_callbacks_registered) && @maglev_callbacks_registered

        after_commit :maglev_reindex, on: %i[create update]
        after_commit :maglev_unindex, on: :destroy
        @maglev_callbacks_registered = true
      end
    end

    def maglev_snapshot
      SnapshotBuilder.new(self, self.class.maglev_config).build.to_s
    end

    def ask(question, limit: 10, user: nil)
      if user
        Answerer.new(self.class).ask(question, limit: limit, owner: self, user: user)
      else
        Answerer.new(self.class).ask(question, limit: limit, owner: self)
      end
    end

    def explain(limit: 10)
      ask(Maglev.configuration.explain_question, limit: limit)
    end

    def maglev_context_preview(question: nil)
      ContextPreview.new(
        text: maglev_snapshot,
        metadata: {question: question, provider_calls: 0}
      )
    end

    private

    def maglev_reindex
      ReindexJob.perform_later(self.class.name, id)
    end

    def maglev_unindex
      Indexer.new(self).unindex
    end
  end
end
