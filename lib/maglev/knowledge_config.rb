# frozen_string_literal: true

require_relative "errors"

module Maglev
  class KnowledgeConfig
    Relation = Struct.new(:name, :depth, :limit, :inverse) do
      def initialize(name:, depth:, limit:, inverse: nil)
        super(name.to_s, depth, limit, inverse&.to_s)
        freeze
      end
    end

    ContentSource = Struct.new(:name) do
      def initialize(name)
        super(name.to_s)
        freeze
      end
    end

    attr_reader :model_class

    def self.build(model_class, &block)
      Builder.new(model_class).build(&block)
    end

    def initialize(model_class:, exposed_attributes:, hidden_attributes:, tags:, relations: [], attached_sources: [], rich_text_sources: [])
      @model_class = model_class
      @exposed_attributes = exposed_attributes.freeze
      @hidden_attributes = hidden_attributes.freeze
      @tags = tags.freeze
      @relations = relations.freeze
      @attached_sources = attached_sources.freeze
      @rich_text_sources = rich_text_sources.freeze
      freeze
    end

    def exposed_attributes
      @exposed_attributes.dup.freeze
    end

    def hidden_attributes
      @hidden_attributes.dup.freeze
    end

    def tags
      @tags.dup.freeze
    end

    def relations
      @relations.dup.freeze
    end

    def attached_sources
      @attached_sources.dup.freeze
    end

    def rich_text_sources
      @rich_text_sources.dup.freeze
    end

    class Builder
      def initialize(model_class)
        @model_class = model_class
        @exposed_attributes = []
        @hidden_attributes = []
        @tags = []
        @relations = []
        @attached_sources = []
        @rich_text_sources = []
      end

      def build(&block)
        instance_eval(&block) if block
        validate!

        KnowledgeConfig.new(
          model_class: @model_class,
          exposed_attributes: normalize(@exposed_attributes),
          hidden_attributes: normalize(@hidden_attributes),
          tags: normalize(@tags),
          relations: @relations.uniq { |relation| relation.name },
          attached_sources: @attached_sources.uniq(&:name),
          rich_text_sources: @rich_text_sources.uniq(&:name)
        )
      end

      def expose(*attributes)
        @exposed_attributes.concat(attributes)
      end

      def hide(*attributes)
        @hidden_attributes.concat(attributes)
      end

      def tags(*tags)
        @tags.concat(tags)
      end

      def include_related(association, depth:, limit:, inverse: nil)
        @relations << Relation.new(name: association, depth: depth, limit: limit, inverse: inverse)
      end

      def expose_attached(*names)
        @attached_sources.concat(names.map { |name| ContentSource.new(name) })
      end

      def expose_rich_text(*names)
        @rich_text_sources.concat(names.map { |name| ContentSource.new(name) })
      end

      private

      def validate!
        unknown_attributes = normalize(@exposed_attributes) - @model_class.attribute_names.map(&:to_s)
        if unknown_attributes.any?
          raise ConfigurationError, "Unknown exposed Maglev attributes for #{@model_class.name}: #{unknown_attributes.join(", ")}"
        end

        conflicts = normalize(@exposed_attributes) & normalize(@hidden_attributes)
        if conflicts.any?
          raise ConfigurationError, "Maglev attributes cannot be both exposed and hidden: #{conflicts.join(", ")}"
        end

        @relations.each do |relation|
          raise ConfigurationError, "Maglev relation #{relation.name} depth must be positive" unless relation.depth.to_i.positive?
          raise ConfigurationError, "Maglev relation #{relation.name} limit must be positive" unless relation.limit.to_i.positive?
        end
      end

      def normalize(values)
        values.map(&:to_s).uniq
      end
    end
  end
end
