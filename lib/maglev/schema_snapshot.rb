# frozen_string_literal: true

require "json"

require_relative "errors"

module Maglev
  class SchemaSnapshot
    DEFAULT_LIMITS = {resources: 12, fields: 40, associations: 20, bytes: 32_768}.freeze

    Field = Struct.new(:name, :type, :null, :enum_values, :description, :synonyms) do
      def initialize(**attributes)
        attributes[:enum_values] = Array(attributes[:enum_values]).freeze
        attributes[:synonyms] = Array(attributes[:synonyms]).freeze
        super
        freeze
      end

      def to_h
        {name: name, type: type, null: null, enum_values: enum_values, description: description, synonyms: synonyms}.freeze
      end
    end

    Association = Struct.new(:name, :resource, :macro, :polymorphic, :description, :synonyms) do
      def initialize(**attributes)
        attributes[:synonyms] = Array(attributes[:synonyms]).freeze
        super
        freeze
      end

      def to_h
        {name: name, resource: resource, macro: macro, polymorphic: polymorphic, description: description, synonyms: synonyms}.freeze
      end
    end

    Resource = Struct.new(:identifier, :description, :synonyms, :table_name, :primary_key, :sti_base, :inheritance_column,
      :fields, :associations, :scopes, :aggregates, :limits, :allow_unscoped_model_queries) do
      def initialize(**attributes)
        attributes[:synonyms] = Array(attributes[:synonyms]).freeze
        attributes[:fields] = attributes.fetch(:fields).freeze
        attributes[:associations] = attributes.fetch(:associations).freeze
        attributes[:scopes] = attributes.fetch(:scopes).freeze
        attributes[:aggregates] = attributes.fetch(:aggregates).freeze
        attributes[:limits] = attributes.fetch(:limits).freeze
        super
        freeze
      end

      def to_h
        {
          identifier: identifier, description: description, synonyms: synonyms, table_name: table_name,
          primary_key: primary_key, sti_base: sti_base, inheritance_column: inheritance_column,
          fields: fields.map(&:to_h).freeze, associations: associations.map(&:to_h).freeze,
          scopes: scopes, aggregates: aggregates, limits: limits,
          allow_unscoped_model_queries: allow_unscoped_model_queries
        }.freeze
      end
    end

    attr_reader :resources, :paths

    def initialize(resources:, paths:, model_classes: {})
      @resources = resources.freeze
      @paths = paths.freeze
      @model_classes = model_classes.freeze
      @hash = {version: 1, resources: @resources.map(&:to_h).freeze, paths: @paths}.freeze
      freeze
    end

    def to_h
      @hash
    end

    def to_json(*arguments)
      @hash.to_json(*arguments)
    end

    def model_class_for(identifier)
      @model_classes[identifier.to_s]
    end

    class Builder
      def initialize(entries, limits: {})
        requested = limits.transform_keys(&:to_sym)
        unknown = requested.keys - DEFAULT_LIMITS.keys
        valid = requested.all? do |key, value|
          value.is_a?(Integer) && ((key == :bytes) ? value.positive? : value >= 0)
        end
        raise ConfigurationError, "invalid schema snapshot limits" if unknown.any? || !valid

        @limits = DEFAULT_LIMITS.merge(requested) { |_key, global, request| [global, request].min }.freeze
        @entries = entries.sort_by(&:identifier).first(@limits.fetch(:resources)).freeze
        @entry_by_identifier = @entries.to_h { |entry| [entry.identifier, entry] }.freeze
        @resource_identifiers = @entries.map(&:identifier).to_h { |identifier| [identifier, true] }.freeze
        @resource_for_model = @entries.to_h { |entry| [entry.model_class.name, entry.identifier] }.freeze
      end

      def build
        resources = @entries.map { |entry| resource_for(entry) }
        snapshot = SchemaSnapshot.new(
          resources: resources,
          paths: paths_for(resources),
          model_classes: @entries.to_h { |entry| [entry.identifier, entry.model_class] }
        )
        if snapshot.to_json.bytesize > @limits.fetch(:bytes)
          raise ConfigurationError, "schema snapshot exceeds #{@limits.fetch(:bytes)} bytes"
        end
        snapshot
      end

      private

      def resource_for(entry)
        model = entry.model_class
        queryable = entry.queryable
        fields = queryable.fields.reject(&:sensitive).sort_by(&:name).first(@limits.fetch(:fields)).map do |declaration|
          column = model.columns_hash.fetch(declaration.name)
          enum_values = declaration.enum_values.empty? ? model.defined_enums.fetch(declaration.name, {}).keys.sort : declaration.enum_values
          Field.new(name: declaration.name, type: column.type, null: column.null, enum_values: enum_values,
            description: declaration.description, synonyms: declaration.synonyms)
        end
        associations = queryable.associations.select { |declaration| @resource_identifiers.key?(declaration.resource) }
          .sort_by(&:name).first(@limits.fetch(:associations)).map do |declaration|
          reflection = model.reflect_on_association(declaration.name.to_sym)
          target = @entry_by_identifier.fetch(declaration.resource)
          unless reflection.polymorphic? || reflection.klass.base_class == target.model_class.base_class
            raise ConfigurationError,
              "Association #{model.name}.#{declaration.name} does not match resource #{declaration.resource}"
          end
          Association.new(name: declaration.name, resource: declaration.resource, macro: reflection.macro,
            polymorphic: !!reflection.polymorphic?, description: declaration.description, synonyms: declaration.synonyms)
        end
        Resource.new(identifier: entry.identifier, description: entry.description, synonyms: entry.synonyms,
          table_name: model.table_name, primary_key: model.primary_key, sti_base: @resource_for_model[model.base_class.name],
          inheritance_column: model.inheritance_column, fields: fields, associations: associations,
          scopes: queryable.scopes.map { |scope| scope_to_h(scope) }.freeze, aggregates: queryable.aggregates,
          limits: queryable.limits, allow_unscoped_model_queries: queryable.allow_unscoped_model_queries)
      end

      def scope_to_h(scope)
        {name: scope.name, description: scope.description, parameters: scope.parameters.transform_values do |parameter|
          {type: parameter.type, required: parameter.required, nullable: parameter.nullable,
           enum_values: parameter.enum_values, minimum: parameter.minimum, maximum: parameter.maximum}.freeze
        end.freeze}.freeze
      end

      def paths_for(resources)
        by_identifier = resources.to_h { |resource| [resource.identifier, resource] }
        resources.flat_map do |resource|
          resource.associations.flat_map do |association|
            first = "#{resource.identifier}.#{association.name}"
            nested = by_identifier[association.resource]&.associations&.map { |child| "#{first}.#{child.name}" } || []
            [first, *nested]
          end
        end.sort.freeze
      end
    end
  end
end
