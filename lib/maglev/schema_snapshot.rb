# frozen_string_literal: true

require "json"

require_relative "errors"

module Maglev
  class SchemaSnapshot
    DEFAULT_LIMITS = {resources: 12, fields: 40, associations: 20, bytes: 32_768}.freeze
    SUPPORTED_ASSOCIATION_MACROS = %i[belongs_to has_one has_many has_and_belongs_to_many].freeze

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

    Association = Struct.new(:name, :resource, :macro, :cardinality, :polymorphic, :description, :synonyms) do
      def initialize(**attributes)
        attributes[:synonyms] = Array(attributes[:synonyms]).freeze
        super
        freeze
      end

      def to_h
        {name: name, resource: resource, macro: macro, cardinality: cardinality, polymorphic: polymorphic,
         description: description, synonyms: synonyms}.freeze
      end
    end

    Resource = Struct.new(:identifier, :description, :synonyms, :table_name, :primary_key, :sti_base, :inheritance_column,
      :fields, :analytical_fields, :associations, :scopes, :aggregates, :grouping, :limits,
      :allow_unscoped_model_queries) do
      def initialize(**attributes)
        attributes[:synonyms] = Array(attributes[:synonyms]).freeze
        attributes[:fields] = attributes.fetch(:fields).freeze
        attributes[:analytical_fields] = Array(attributes[:analytical_fields]).freeze
        attributes[:associations] = attributes.fetch(:associations).freeze
        attributes[:scopes] = attributes.fetch(:scopes).freeze
        attributes[:aggregates] = attributes.fetch(:aggregates).freeze
        attributes[:grouping] = Array(attributes[:grouping]).freeze
        attributes[:limits] = attributes.fetch(:limits).freeze
        super
        freeze
      end

      def to_h
        {
          identifier: identifier, description: description, synonyms: synonyms, table_name: table_name,
          primary_key: primary_key, sti_base: sti_base, inheritance_column: inheritance_column,
          fields: fields.map(&:to_h).freeze,
          analytical_fields: analytical_fields.map(&:to_h).freeze,
          associations: associations.map(&:to_h).freeze,
          scopes: scopes, aggregates: aggregates, grouping: grouping, limits: limits,
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
      def initialize(entries, limits: {}, registered_entries: entries)
        requested = limits.transform_keys(&:to_sym)
        unknown = requested.keys - DEFAULT_LIMITS.keys
        valid = requested.all? do |key, value|
          value.is_a?(Integer) && ((key == :bytes) ? value.positive? : value >= 0)
        end
        raise ConfigurationError, "invalid schema snapshot limits" if unknown.any? || !valid

        @limits = DEFAULT_LIMITS.merge(requested) { |_key, global, request| [global, request].min }.freeze
        @entries = entries.sort_by(&:identifier).first(@limits.fetch(:resources)).freeze
        @entry_by_identifier = @entries.to_h { |entry| [entry.identifier, entry] }.freeze
        @registered_entry_by_identifier = registered_entries.to_h { |entry| [entry.identifier, entry] }.freeze
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
          Field.new(name: declaration.name, type: declaration.type, null: declaration.null, enum_values: declaration.enum_values,
            description: declaration.description, synonyms: declaration.synonyms)
        end
        analytical_names = [
          *queryable.grouping,
          *queryable.aggregates.values.reject { |value| value == true }.flatten
        ].uniq - fields.map(&:name)
        analytical_fields = analytical_names.sort.first(@limits.fetch(:fields)).filter_map do |name|
          declaration = queryable.fields.find { |field| field.name == name }
          column = model.columns_hash[name]
          next unless column

          Field.new(name: name, type: column.type, null: column.null,
            enum_values: model.defined_enums.fetch(name, {}).keys.sort,
            description: declaration&.description, synonyms: declaration&.synonyms)
        end
        associations = queryable.associations.filter_map do |declaration|
          reflection = model.reflect_on_association(declaration.name.to_sym)
          unless reflection && SUPPORTED_ASSOCIATION_MACROS.include?(reflection.macro)
            macro = reflection&.macro || :unresolved
            raise ConfigurationError,
              "Unsupported association #{model.name}.#{declaration.name} (#{macro})"
          end
          target = target_entry_for(model, reflection, declaration)
          next unless target

          unless reflection.polymorphic? || reflection.klass.base_class == target.model_class.base_class
            raise ConfigurationError,
              "Association #{model.name}.#{declaration.name} does not match resource #{target.identifier}"
          end
          Association.new(name: declaration.name, resource: target.identifier, macro: reflection.macro,
            cardinality: association_cardinality(reflection),
            polymorphic: !!reflection.polymorphic?, description: declaration.description, synonyms: declaration.synonyms)
        end.sort_by(&:name).first(@limits.fetch(:associations))
        Resource.new(identifier: entry.identifier, description: entry.description, synonyms: entry.synonyms,
          table_name: model.table_name, primary_key: model.primary_key, sti_base: @resource_for_model[model.base_class.name],
          inheritance_column: model.inheritance_column, fields: fields, analytical_fields: analytical_fields,
          associations: associations,
          scopes: queryable.scopes.map { |scope| scope_to_h(scope) }.freeze, aggregates: queryable.aggregates,
          grouping: queryable.grouping,
          limits: queryable.limits, allow_unscoped_model_queries: queryable.allow_unscoped_model_queries)
      end

      def scope_to_h(scope)
        {name: scope.name, description: scope.description, parameters: scope.parameters.transform_values do |parameter|
          {type: parameter.type, required: parameter.required, nullable: parameter.nullable,
           enum_values: parameter.enum_values, minimum: parameter.minimum, maximum: parameter.maximum}.freeze
        end.freeze}.freeze
      end

      def target_entry_for(model, reflection, declaration)
        if declaration.resource
          unless @registered_entry_by_identifier.key?(declaration.resource)
            raise ConfigurationError,
              "Association #{model.name}.#{declaration.name} references unregistered resource #{declaration.resource}"
          end

          return @entry_by_identifier[declaration.resource]
        end
        if reflection.polymorphic?
          raise ConfigurationError,
            "Polymorphic association #{model.name}.#{declaration.name} requires an explicit target resource"
        end

        target_class = reflection.klass
        @entries.find { |entry| entry.model_class == target_class }
      rescue NameError => error
        raise ConfigurationError,
          "Cannot resolve association #{model.name}.#{declaration.name}: #{error.message}"
      end

      def association_cardinality(reflection)
        reflection.collection? ? :many : :one
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
