# frozen_string_literal: true

require_relative "errors"

module Maglev
  class KnowledgeConfig
    Relation = Struct.new(:name, :depth, :limit, :inverse, :order) do
      def initialize(name:, depth:, limit:, inverse: nil, order: nil)
        super(name.to_s, depth, limit, inverse&.to_s, order&.dup&.freeze)
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

    def initialize(model_class:, tags:, content_attributes: nil, context_attributes: [], prohibited_attributes: nil,
      exposed_attributes: nil, hidden_attributes: nil, relations: [], attached_sources: [], rich_text_sources: [])
      @model_class = model_class
      @content_attributes = (content_attributes || exposed_attributes || []).freeze
      @context_attributes = context_attributes.freeze
      @prohibited_attributes = (prohibited_attributes || hidden_attributes || []).freeze
      @tags = tags.freeze
      @relations = relations.freeze
      @attached_sources = attached_sources.freeze
      @rich_text_sources = rich_text_sources.freeze
      freeze
    end

    def content_attributes
      @content_attributes.dup.freeze
    end

    def context_attributes
      @context_attributes.dup.freeze
    end

    def prohibited_attributes
      @prohibited_attributes.dup.freeze
    end

    alias_method :exposed_attributes, :content_attributes
    alias_method :hidden_attributes, :prohibited_attributes

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
        @content_attributes = []
        @context_attributes = []
        @prohibited_attributes = []
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
          content_attributes: permitted(@content_attributes),
          context_attributes: permitted(@context_attributes),
          prohibited_attributes: normalize(@prohibited_attributes),
          tags: normalize(@tags),
          relations: @relations.uniq { |relation| relation.name },
          attached_sources: @attached_sources.uniq(&:name),
          rich_text_sources: @rich_text_sources.uniq(&:name)
        )
      end

      def content(*attributes)
        @content_attributes.concat(attributes)
      end

      def context(*attributes)
        @context_attributes.concat(attributes)
      end

      def prohibit(*attributes)
        @prohibited_attributes.concat(attributes)
      end

      alias_method :expose, :content
      alias_method :hide, :prohibit

      def tags(*tags)
        @tags.concat(tags)
      end

      def include_related(association, depth:, limit:, inverse: nil, order: nil)
        normalized_order = normalize_order(order)
        @relations << Relation.new(name: association, depth: depth, limit: limit, inverse: inverse, order: normalized_order)
      end

      def expose_attached(*names)
        @attached_sources.concat(names.map { |name| ContentSource.new(name) })
      end

      def expose_rich_text(*names)
        @rich_text_sources.concat(names.map { |name| ContentSource.new(name) })
      end

      private

      def validate!
        declared = normalize(@content_attributes + @context_attributes + @prohibited_attributes)
        unknown_attributes = declared - @model_class.attribute_names.map(&:to_s)
        if unknown_attributes.any?
          raise ConfigurationError, "Unknown Maglev knowledge attributes for #{@model_class.name}: #{unknown_attributes.join(", ")}"
        end

        conflicts = normalize(@content_attributes) & normalize(@context_attributes)
        if conflicts.any?
          raise ConfigurationError, "Maglev attributes cannot be both content and context: #{conflicts.join(", ")}"
        end

        if permitted(@content_attributes).empty? && @attached_sources.empty? && @rich_text_sources.empty?
          raise ConfigurationError, "Maglev knowledge for #{@model_class.name} requires at least one content attribute"
        end

        @relations.each do |relation|
          raise ConfigurationError, "Maglev relation #{relation.name} depth must be positive" unless relation.depth.to_i.positive?
          raise ConfigurationError, "Maglev relation #{relation.name} limit must be positive" unless relation.limit.to_i.positive?
        end
      end

      def normalize(values)
        values.map(&:to_s).uniq
      end

      def permitted(values)
        normalize(values) - normalize(@prohibited_attributes)
      end

      VALID_DIRECTIONS = %i[asc desc].freeze

      def normalize_order(order)
        return nil if order.nil?

        case order
        when Symbol, String
          {order.to_sym => :asc}
        when Hash
          raise ConfigurationError, "Maglev relation order Hash cannot be empty" if order.empty?

          order.each do |column, direction|
            raise ConfigurationError, "Maglev relation order direction must be :asc or :desc, got: #{direction.inspect}" unless VALID_DIRECTIONS.include?(direction)
            raise ConfigurationError, "Maglev relation order column must be a Symbol or String, got: #{column.inspect}" unless column.is_a?(Symbol) || column.is_a?(String)
          end
          order.to_h { |col, dir| [col.to_sym, dir.to_sym] }
        else
          raise ConfigurationError, "Maglev relation order must be a Symbol, String, or Hash, got: #{order.class}"
        end
      end
    end
  end
end
