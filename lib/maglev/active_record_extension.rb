# frozen_string_literal: true

require "active_support/concern"

require_relative "answerer"
require_relative "chunker"
require_relative "content_source_graph"
require_relative "context_preview"
require_relative "dependency_graph"
require_relative "knowledge_config"
require_relative "knowledge_registry"
require_relative "registry"
require_relative "indexer"
require_relative "reindex_job"
require_relative "retriever"
require_relative "request_executor"
require_relative "schema_compiler"
require_relative "snapshot_builder"
require_relative "snapshot"

module Maglev
  module ActiveRecordExtension
    extend ActiveSupport::Concern

    class_methods do
      def maglev_resource(identifier, &block)
        @maglev_resource_identifier = identifier.to_s
        @maglev_resource_declaration = block
        KnowledgeRegistry.register(name)
        rebuild_maglev_resource_registration
      end

      def rebuild_maglev_resource_registration
        return unless @maglev_resource_identifier

        entry = ResourceConfig::Builder.new(self, @maglev_resource_identifier).build(&@maglev_resource_declaration)
        Registry.register(entry)
        if entry.knowledge
          @maglev_config = entry.knowledge
          rebuild_maglev_registration
        else
          clear_maglev_registration
        end
        entry
      end

      def rebuild_maglev_registry_registration
        rebuild_maglev_resource_registration if @maglev_resource_identifier
      end

      def rebuild_maglev_registration
        return unless @maglev_config

        DependencyGraph.unregister(self)
        @maglev_schema = SchemaCompiler.new(@maglev_config).compile if @maglev_config.relations.any?
        @maglev_schema = nil if @maglev_config.relations.empty?
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

      def search(query, limit: 10, user: nil, minimum_similarity: nil)
        maglev_knowledge_config!
        Retriever.new(self).search(query, limit: limit, user: user, minimum_similarity: minimum_similarity)
      end

      def retrieve(query, limit: 10, user: nil, minimum_similarity: nil, chunks_per_owner: 1)
        maglev_knowledge_config!
        Retriever.new(self).retrieve(query, limit: limit, user: user,
          minimum_similarity: minimum_similarity, chunks_per_owner: chunks_per_owner)
      end

      def maglev_schema
        config = maglev_config
        relations = if @maglev_schema
          @maglev_schema.relations.map do |relation|
            {
              name: relation.name,
              depth: relation.depth,
              limit: relation.limit,
              inverse: relation.inverse,
              order: relation.order,
              macro: relation.macro,
              related_model: relation.related_class.name
            }.freeze
          end.freeze
        else
          [].freeze
        end
        {
          model: name,
          exposed_attributes: config&.exposed_attributes || [].freeze,
          relations: relations,
          attached_sources: (config&.attached_sources&.map(&:name) || []).freeze,
          rich_text_sources: (config&.rich_text_sources&.map(&:name) || []).freeze
        }.freeze
      end

      def ask(question, limit: 10, user: nil, minimum_similarity: nil, chunks_per_owner: nil)
        maglev_knowledge_config!
        Answerer.new(self).ask(question, limit: limit, user: user, minimum_similarity: minimum_similarity, chunks_per_owner: chunks_per_owner)
      end

      def maglev_request(question, **options)
        Maglev.request(question, models: [self], **options)
      end

      private

      def maglev_knowledge_config!
        maglev_config || raise(ConfigurationError, "#{name} must declare maglev_resource knowledge")
      end

      def clear_maglev_registration
        @maglev_config = nil
        @maglev_schema = nil
        DependencyGraph.unregister(self)
        unregister_maglev_callbacks
      end

      def register_maglev_callbacks
        after_commit :maglev_reindex, on: %i[create update] unless maglev_callback_registered?(:maglev_reindex)
        after_commit :maglev_unindex, on: :destroy unless maglev_callback_registered?(:maglev_unindex)
        @maglev_registered_callback_filters = %i[maglev_reindex maglev_unindex]
      end

      def unregister_maglev_callbacks
        if respond_to?(:skip_callback)
          skip_callback(:commit, :after, :maglev_reindex, raise: false)
          skip_callback(:commit, :after, :maglev_unindex, raise: false)
        end
        @maglev_registered_callback_filters = []
      end

      def maglev_callback_registered?(filter)
        if respond_to?(:_commit_callbacks)
          _commit_callbacks.any? { |callback| callback.filter == filter }
        else
          Array(@maglev_registered_callback_filters).include?(filter)
        end
      end
    end

    def maglev_snapshot
      maglev_snapshot_result.to_s
    end

    def maglev_index_status
      IndexDiagnostics.status(owner_type: self.class.name, owner_id: id)
    end

    def maglev_snapshot_result
      snapshot = SnapshotBuilder.new(self, maglev_knowledge_config!).build
      chunks = Chunker.new(max_characters: Maglev.configuration.chunk_size, max_chunks: nil).call(snapshot.to_s)
      retained = [chunks.length, Maglev.configuration.snapshot_max_chunks].min
      return snapshot if chunks.length == retained

      source = {
        kind: :chunks,
        path: "snapshot.chunks",
        original_chunks: chunks.length,
        retained_chunks: retained
      }
      metadata = snapshot.metadata.merge(
        truncated: true,
        sources: snapshot.metadata.fetch(:sources, []) + [source]
      )
      Snapshot.new([snapshot.to_s], metadata: metadata)
    end

    def ask(question, limit: 10, user: nil, minimum_similarity: nil, chunks_per_owner: nil)
      maglev_knowledge_config!
      Answerer.new(self.class).ask(question, limit: limit, owner: self, user: user,
        minimum_similarity: minimum_similarity, chunks_per_owner: chunks_per_owner)
    end

    def explain(limit: 10)
      ask(Maglev.configuration.explain_question, limit: limit)
    end

    def maglev_context_preview(question: nil)
      snapshot = maglev_snapshot_result
      ContextPreview.new(
        text: snapshot.to_s,
        metadata: snapshot.metadata.merge(question: question, provider_calls: 0)
      )
    end

    private

    def maglev_knowledge_config!
      self.class.maglev_config || raise(ConfigurationError, "#{self.class.name} must declare maglev_resource knowledge")
    end

    def maglev_reindex
      ReindexJob.perform_later(self.class.name, id)
    end

    def maglev_unindex
      Indexer.new(self).unindex
    end
  end

  module RelationExtension
    def maglev_request(question, **options)
      Maglev.request(question, models: [klass], base_relation: self, **options)
    end
  end
end
