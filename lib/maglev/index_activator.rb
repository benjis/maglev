# frozen_string_literal: true

require_relative "index_generation"
require_relative "index_rebuilder"
require_relative "registry"

module Maglev
  class IndexActivator
    def initialize(generation,
      embedding_adapter: Maglev.configuration.embedding_adapter,
      embedding_dimensions: Maglev.configuration.embedding_dimensions,
      chunk_size: Maglev.configuration.chunk_size)
      @generation = generation
      @resources = registered_resources
      @embedding_adapter = embedding_adapter
      @embedding_dimensions = embedding_dimensions
      @chunk_size = chunk_size
    end

    def activate!
      IndexGeneration.transaction do
        lock_resource_tables
        current_manifest = IndexRebuilder.manifest_for(
          resources: @resources,
          embedding_adapter: @embedding_adapter,
          embedding_dimensions: @embedding_dimensions,
          chunk_size: @chunk_size
        )
        @generation.cutover!(current_manifest: current_manifest)
      end
    end

    private

    def registered_resources
      entries = Registry.entries.select(&:knowledge)
      registered_identifiers = entries.map(&:identifier).sort
      return entries.map(&:model_class) if @generation.manifest.keys.sort == registered_identifiers

      raise IndexGeneration::InvalidCutover,
        "index generation manifest does not cover every registered knowledge resource"
    end

    def lock_resource_tables
      connection = IndexGeneration.connection
      return unless connection.adapter_name == "PostgreSQL"

      models, table_names = knowledge_dependencies
      unless models.all? do |model|
        !model.respond_to?(:connection_pool) || model.connection_pool == IndexGeneration.connection_pool
      end
        raise IndexGeneration::InvalidCutover,
          "atomic activation requires every knowledge source to share the index generation database"
      end

      table_names.uniq.select { |table_name| connection.data_source_exists?(table_name) }.sort.each do |table_name|
        connection.execute("LOCK TABLE #{connection.quote_table_name(table_name)} IN SHARE MODE")
      end
    end

    def knowledge_dependencies
      models = @resources.dup
      tables = @resources.filter_map { |model| model.table_name if model.respond_to?(:table_name) }
      @resources.each do |model|
        config = model.maglev_config if model.respond_to?(:maglev_config)
        next unless config

        config.relations.each do |relation|
          reflection = model.reflect_on_association(relation.name) if model.respond_to?(:reflect_on_association)
          next unless reflection

          add_reflection_dependencies(reflection, models, tables)
        end
        add_framework_dependencies(config, models, tables)
      end
      [models.uniq, tables.uniq]
    end

    def add_reflection_dependencies(reflection, models, tables)
      related_model = reflection.klass unless reflection.polymorphic?
      models << related_model if related_model
      tables << related_model.table_name if related_model&.respond_to?(:table_name)
      tables << reflection.join_table if reflection.respond_to?(:join_table) && reflection.join_table

      through = reflection.through_reflection if reflection.respond_to?(:through_reflection)
      add_reflection_dependencies(through, models, tables) if through
    rescue NameError
      raise IndexGeneration::InvalidCutover, "a knowledge relation could not be resolved for atomic activation"
    end

    def add_framework_dependencies(config, models, tables)
      if config.attached_sources.any?
        unless defined?(ActiveStorage::Attachment) && defined?(ActiveStorage::Blob)
          raise IndexGeneration::InvalidCutover,
            "attachment knowledge sources cannot be resolved for atomic activation"
        end

        models.concat([ActiveStorage::Attachment, ActiveStorage::Blob])
        tables.concat([ActiveStorage::Attachment.table_name, ActiveStorage::Blob.table_name])
      end
      return unless config.rich_text_sources.any?
      unless defined?(ActionText::RichText)
        raise IndexGeneration::InvalidCutover,
          "rich text knowledge sources cannot be resolved for atomic activation"
      end

      models << ActionText::RichText
      tables << ActionText::RichText.table_name
    end
  end
end
