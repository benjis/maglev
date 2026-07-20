# frozen_string_literal: true

require_relative "errors"
require_relative "knowledge_config"

module Maglev
  class ResourceConfig
    SUPPORTED_PARAMETER_TYPES = %i[
      string integer float decimal boolean date datetime timestamp time
    ].freeze

    Field = Struct.new(:name, :description, :synonyms, :enum_values, :sensitive) do
      def initialize(**attributes)
        attributes[:name] = attributes.fetch(:name).to_s
        attributes[:description] = attributes[:description]&.to_s
        attributes[:synonyms] = Array(attributes[:synonyms]).map(&:to_s).uniq.freeze
        attributes[:enum_values] = Array(attributes[:enum_values]).map(&:to_s).uniq.freeze
        attributes[:sensitive] = !!attributes[:sensitive]
        super
        freeze
      end
    end

    Association = Struct.new(:name, :resource, :description, :synonyms) do
      def initialize(**attributes)
        attributes[:name] = attributes.fetch(:name).to_s
        attributes[:resource] = attributes.fetch(:resource).to_s
        attributes[:description] = attributes[:description]&.to_s
        attributes[:synonyms] = Array(attributes[:synonyms]).map(&:to_s).uniq.freeze
        super
        freeze
      end
    end

    Parameter = Struct.new(:type, :required, :nullable, :enum_values, :minimum, :maximum) do
      def initialize(**attributes)
        attributes[:type] = attributes.fetch(:type).to_sym
        unless SUPPORTED_PARAMETER_TYPES.include?(attributes[:type])
          raise ConfigurationError, "Unsupported scope parameter type #{attributes[:type]}"
        end
        attributes[:required] = !!attributes[:required]
        attributes[:nullable] = !!attributes[:nullable]
        attributes[:enum_values] = Array(attributes[:enum_values]).map(&:to_s).uniq.freeze
        super
        freeze
      end
    end

    Scope = Struct.new(:name, :parameters, :description) do
      def initialize(**attributes)
        attributes[:name] = attributes.fetch(:name).to_s
        attributes[:parameters] = attributes.fetch(:parameters).to_h { |name, parameter| [name.to_s, parameter] }.freeze
        attributes[:description] = attributes[:description]&.to_s
        super
        freeze
      end
    end

    Queryable = Struct.new(:fields, :prohibited_fields, :associations, :scopes, :aggregates, :limits, :authorization, :allow_unscoped_model_queries) do
      def initialize(**attributes)
        attributes[:fields] = attributes.fetch(:fields).freeze
        attributes[:prohibited_fields] = attributes.fetch(:prohibited_fields).freeze
        attributes[:associations] = attributes.fetch(:associations).freeze
        attributes[:scopes] = attributes.fetch(:scopes).freeze
        attributes[:aggregates] = attributes.fetch(:aggregates).transform_values { |values| (values == true) ? true : Array(values).freeze }.freeze
        attributes[:limits] = attributes.fetch(:limits).freeze
        attributes[:authorization] = attributes.fetch(:authorization)
        attributes[:allow_unscoped_model_queries] = !!attributes[:allow_unscoped_model_queries]
        super
        freeze
      end
    end

    Entry = Struct.new(:identifier, :model_class, :description, :synonyms, :queryable, :knowledge) do
      def initialize(**attributes)
        attributes[:identifier] = attributes.fetch(:identifier).to_s
        attributes[:description] = attributes[:description]&.to_s
        attributes[:synonyms] = Array(attributes[:synonyms]).map(&:to_s).uniq.freeze
        super
        freeze
      end
    end

    class Builder
      def initialize(model_class, identifier)
        @model_class = model_class
        @identifier = identifier
        @synonyms = []
      end

      def build(&block)
        instance_eval(&block) if block
        Entry.new(identifier: @identifier, model_class: @model_class, description: @description,
          synonyms: @synonyms, queryable: @queryable, knowledge: @knowledge)
      end

      def description(value)
        @description = value.to_s
      end

      def synonyms(*values)
        @synonyms.concat(values)
      end

      def queryable(&block)
        raise ConfigurationError, "queryable may only be declared once" if @queryable

        @queryable = QueryableBuilder.new(@model_class).build(&block)
      end

      def knowledge(&block)
        raise ConfigurationError, "knowledge may only be declared once" if @knowledge

        @knowledge = KnowledgeConfig.build(@model_class, &block)
        validate_knowledge_sources!
      end

      private

      def validate_knowledge_sources!
        @knowledge.attached_sources.each do |source|
          reflection = @model_class.reflect_on_association("#{source.name}_attachment") ||
            @model_class.reflect_on_association("#{source.name}_attachments")
          raise ConfigurationError, "Unknown attached knowledge source #{@model_class.name}.#{source.name}" unless reflection
        end
      end
    end

    class QueryableBuilder
      AUTHORIZATION_POLICIES = %i[required public].freeze
      LIMIT_KEYS = %i[rows operations joins].freeze
      AGGREGATES = %i[count sum average minimum maximum].freeze

      def initialize(model_class)
        @model_class = model_class
        @fields = []
        @prohibited_fields = []
        @associations = []
        @scopes = []
        @aggregates = {}
        @limits = {}
        @authorization = :required
        @allow_unscoped_model_queries = false
      end

      def build(&block)
        instance_eval(&block) if block
        conflicts = @fields.map(&:name) & @prohibited_fields
        raise ConfigurationError, "Queryable fields cannot be prohibited: #{conflicts.join(", ")}" if conflicts.any?

        Queryable.new(fields: @fields.uniq(&:name), prohibited_fields: @prohibited_fields.uniq.freeze,
          associations: @associations.uniq(&:name), scopes: @scopes.uniq(&:name),
          aggregates: @aggregates, limits: @limits, authorization: @authorization,
          allow_unscoped_model_queries: @allow_unscoped_model_queries)
      end

      def field(name, description: nil, synonyms: [], enum: [], sensitive: false)
        normalized = name.to_s
        raise ConfigurationError, "Unknown queryable field #{@model_class.name}.#{normalized}" unless @model_class.attribute_names.include?(normalized)

        @fields << Field.new(name: normalized, description: description, synonyms: synonyms, enum_values: enum, sensitive: sensitive)
      end

      def association(name, resource:, description: nil, synonyms: [])
        normalized = name.to_s
        raise ConfigurationError, "Unknown queryable association #{@model_class.name}.#{normalized}" unless @model_class.reflect_on_association(normalized.to_sym)

        @associations << Association.new(name: normalized, resource: resource, description: description, synonyms: synonyms)
      end

      def prohibit(*names)
        normalized = names.map(&:to_s)
        unknown = normalized - @model_class.attribute_names
        raise ConfigurationError, "Unknown prohibited field #{@model_class.name}.#{unknown.first}" if unknown.any?

        @prohibited_fields.concat(normalized)
      end

      def scope(name, parameters: {}, description: nil)
        normalized = name.to_s
        raise ConfigurationError, "Unknown queryable scope #{@model_class.name}.#{normalized}" unless @model_class.respond_to?(normalized)

        normalized_parameters = parameters.to_h do |parameter_name, schema|
          schema = schema.transform_keys(&:to_sym)
          [parameter_name, Parameter.new(**schema)]
        end
        @scopes << Scope.new(name: normalized, parameters: normalized_parameters, description: description)
      end

      def aggregates(**permissions)
        unknown = permissions.keys - AGGREGATES
        raise ConfigurationError, "Unknown aggregates: #{unknown.join(", ")}" if unknown.any?

        permissions.each do |aggregate, fields|
          normalized = (fields == true) ? true : Array(fields).map(&:to_s).uniq
          unknown_fields = (normalized == true) ? [] : Array(normalized) - @model_class.attribute_names
          raise ConfigurationError, "Unknown aggregate field #{@model_class.name}.#{unknown_fields.first}" if unknown_fields.any?
          @aggregates[aggregate] = normalized
        end
      end

      def limits(**values)
        unknown = values.keys - LIMIT_KEYS
        raise ConfigurationError, "Unknown query limits: #{unknown.join(", ")}" if unknown.any?
        raise ConfigurationError, "Query limits must be positive integers" unless values.values.all? { |value| value.is_a?(Integer) && value.positive? }

        @limits.merge!(values)
      end

      def authorization(policy)
        policy = policy.to_sym
        raise ConfigurationError, "Unknown authorization policy #{policy}" unless AUTHORIZATION_POLICIES.include?(policy)

        @authorization = policy
      end

      def allow_unscoped_model_queries(value = true)
        @allow_unscoped_model_queries = value
      end
    end
  end
end
