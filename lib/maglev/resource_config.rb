# frozen_string_literal: true

require_relative "errors"
require_relative "knowledge_config"

module Maglev
  class ResourceConfig
    SUPPORTED_PARAMETER_TYPES = %i[
      string integer float decimal boolean date datetime timestamp time
    ].freeze

    Field = Struct.new(:name, :type, :null, :description, :synonyms, :enum_values, :sensitive) do
      def initialize(**attributes)
        attributes[:name] = attributes.fetch(:name).to_s
        attributes[:type] = attributes.fetch(:type).to_sym
        attributes[:null] = !!attributes.fetch(:null)
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
        attributes[:resource] = attributes[:resource]&.to_s
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

    Queryable = Struct.new(:fields, :prohibited_fields, :associations, :prohibited_associations,
      :scopes, :aggregates, :grouping, :limits, :authorization, :allow_unscoped_model_queries) do
      def initialize(**attributes)
        attributes[:fields] = attributes.fetch(:fields).freeze
        attributes[:prohibited_fields] = attributes.fetch(:prohibited_fields).freeze
        attributes[:associations] = attributes.fetch(:associations).freeze
        attributes[:prohibited_associations] = attributes.fetch(:prohibited_associations).freeze
        attributes[:scopes] = attributes.fetch(:scopes).freeze
        attributes[:aggregates] = attributes.fetch(:aggregates).transform_values { |values| (values == true) ? true : Array(values).freeze }.freeze
        attributes[:grouping] = Array(attributes[:grouping]).freeze
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
        build_reflected_queryable! unless @queryable
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

        @queryable = QueryableBuilder.new(@model_class).build(reflect: true, &block)
      end

      def knowledge(&block)
        raise ConfigurationError, "knowledge may only be declared once" if @knowledge

        @knowledge = KnowledgeConfig.build(@model_class, &block)
        validate_knowledge_sources!
      end

      private

      def build_reflected_queryable!
        return unless @model_class.respond_to?(:columns_hash)
        if @model_class.respond_to?(:table_exists?) && !@model_class.table_exists?
          return if @knowledge

          raise ConfigurationError,
            "Cannot reflect #{@model_class.name}: table #{@model_class.table_name} does not exist"
        end

        @queryable = QueryableBuilder.new(@model_class).build(reflect: true)
      end

      def validate_knowledge_sources!
        @knowledge.attached_sources.each do |source|
          reflection = @model_class.reflect_on_association("#{source.name}_attachment") ||
            @model_class.reflect_on_association("#{source.name}_attachments")
          raise ConfigurationError, "Unknown attached knowledge source #{@model_class.name}.#{source.name}" unless reflection
        end
        @knowledge.rich_text_sources.each do |source|
          reflection = @model_class.reflect_on_association("rich_text_#{source.name}")
          valid = reflection&.class_name == "ActionText::RichText" && @model_class.method_defined?(source.name)
          raise ConfigurationError, "Unknown rich text knowledge source #{@model_class.name}.#{source.name}" unless valid
        end
      end
    end

    class QueryableBuilder
      AUTHORIZATION_POLICIES = %i[required public].freeze
      LIMIT_KEYS = %i[rows groups operations joins].freeze
      AGGREGATES = %i[count sum average minimum maximum].freeze
      NUMERIC_TYPES = %i[integer float decimal].freeze
      ORDERED_TYPES = (NUMERIC_TYPES + %i[date datetime timestamp time]).freeze
      GROUPABLE_TYPES = %i[string integer float decimal boolean date datetime timestamp time].freeze

      def initialize(model_class)
        @model_class = model_class
        @fields = []
        @field_annotations = {}
        @prohibited_fields = []
        @associations = []
        @association_annotations = {}
        @prohibited_associations = []
        @scopes = []
        @aggregates = {}
        @grouping = []
        @limits = {}
        @authorization = :required
        @allow_unscoped_model_queries = false
      end

      def build(reflect: false, &block)
        instance_eval(&block) if block
        reflect_fields! if reflect && !@field_allowlist
        reflect_associations! if reflect && !@association_allowlist
        apply_field_annotations!
        apply_association_annotations!
        @fields.reject! { |field| @prohibited_fields.include?(field.name) }
        @associations.reject! { |association| @prohibited_associations.include?(association.name) }
        infer_aggregate_and_grouping_capabilities!

        Queryable.new(fields: @fields.uniq(&:name), prohibited_fields: @prohibited_fields.uniq.freeze,
          associations: @associations.uniq(&:name), prohibited_associations: @prohibited_associations.uniq.freeze,
          scopes: @scopes.uniq(&:name),
          aggregates: @aggregates, grouping: @grouping, limits: @limits, authorization: @authorization,
          allow_unscoped_model_queries: @allow_unscoped_model_queries)
      end

      def field(name, description: nil, synonyms: [], enum: [], sensitive: false)
        normalized = name.to_s
        column = reflectable_column(normalized)
        raise ConfigurationError, "Unknown queryable field #{@model_class.name}.#{normalized}" unless column
        annotation = @field_annotations[normalized]
        conflicts = annotation_conflicts(description: description, synonyms: synonyms, annotation: annotation)
        raise_annotation_conflict!(normalized, conflicts) if conflicts.any?

        @fields.clear unless @field_allowlist
        @field_allowlist = true
        @fields << reflected_field(column, description: description, synonyms: synonyms, enum_values: enum, sensitive: sensitive)
      end

      def annotate_field(name, description: nil, synonyms: [])
        normalized = name.to_s
        unless reflectable_column(normalized)
          raise ConfigurationError, "Unknown annotated field #{@model_class.name}.#{normalized}"
        end
        if @field_annotations.key?(normalized)
          raise ConfigurationError, "Field annotation declared more than once for #{@model_class.name}.#{normalized}"
        end

        annotation = {}
        annotation[:description] = description unless description.nil?
        annotation[:synonyms] = synonyms unless Array(synonyms).empty?
        field = @fields.find { |candidate| candidate.name == normalized }
        conflicts = annotation_conflicts(description: field&.description, synonyms: field&.synonyms, annotation: annotation)
        raise_annotation_conflict!(normalized, conflicts) if conflicts.any?

        @field_annotations[normalized] = annotation.freeze
      end

      def association(name, resource: nil, description: nil, synonyms: [])
        normalized = name.to_s
        raise ConfigurationError, "Unknown queryable association #{@model_class.name}.#{normalized}" unless @model_class.reflect_on_association(normalized.to_sym)
        annotation = @association_annotations[normalized]
        conflicts = annotation_conflicts(description: description, synonyms: synonyms, annotation: annotation)
        raise_association_annotation_conflict!(normalized, conflicts) if conflicts.any?

        @associations.clear unless @association_allowlist
        @association_allowlist = true
        @associations << Association.new(name: normalized, resource: resource, description: description, synonyms: synonyms)
      end

      def annotate_association(name, description: nil, synonyms: [])
        normalized = name.to_s
        unless @model_class.reflect_on_association(normalized.to_sym)
          raise ConfigurationError, "Unknown annotated association #{@model_class.name}.#{normalized}"
        end
        if @association_annotations.key?(normalized)
          raise ConfigurationError, "Association annotation declared more than once for #{@model_class.name}.#{normalized}"
        end

        annotation = {}
        annotation[:description] = description unless description.nil?
        annotation[:synonyms] = synonyms unless Array(synonyms).empty?
        association = @associations.find { |candidate| candidate.name == normalized }
        conflicts = annotation_conflicts(
          description: association&.description,
          synonyms: association&.synonyms,
          annotation: annotation
        )
        raise_association_annotation_conflict!(normalized, conflicts) if conflicts.any?

        @association_annotations[normalized] = annotation.freeze
      end

      def prohibit(*names)
        normalized = names.map(&:to_s)
        unknown = normalized.reject { |name| reflectable_column(name) }
        raise ConfigurationError, "Unknown prohibited field #{@model_class.name}.#{unknown.first}" if unknown.any?

        @prohibited_fields.concat(normalized)
      end

      def prohibit_association(*names)
        normalized = names.map(&:to_s)
        unknown = normalized.reject { |name| @model_class.reflect_on_association(name.to_sym) }
        if unknown.any?
          raise ConfigurationError, "Unknown prohibited association #{@model_class.name}.#{unknown.first}"
        end

        @prohibited_associations.concat(normalized)
      end

      def scope(name, parameters: {}, description: nil)
        normalized = name.to_s
        raise ConfigurationError, "Unknown queryable scope #{@model_class.name}.#{normalized}" unless @model_class.respond_to?(normalized)

        normalized_parameters = parameters.to_h do |parameter_name, schema|
          schema = schema.transform_keys(&:to_sym)
          [parameter_name, Parameter.new(**schema)]
        end
        optional_seen = false
        normalized_parameters.each_value do |parameter|
          if parameter.required && optional_seen
            raise ConfigurationError, "Required scope parameters must precede optional parameters"
          end
          optional_seen ||= !parameter.required
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
          incompatible = if normalized == true
            []
          else
            normalized.reject { |name| aggregate_compatible?(aggregate, @model_class.columns_hash.fetch(name).type) }
          end
          if incompatible.any?
            raise ConfigurationError,
              "Aggregate #{aggregate} is incompatible with #{@model_class.name}.#{incompatible.first}"
          end
          @aggregates[aggregate] = normalized
        end
        @aggregate_allowlist = true
      end

      def grouping(*names)
        normalized = names.flatten.map(&:to_s).uniq
        unknown = normalized.reject { |name| reflectable_column(name) }
        raise ConfigurationError, "Unknown grouping field #{@model_class.name}.#{unknown.first}" if unknown.any?

        @grouping = normalized
        @grouping_allowlist = true
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

      private

      def infer_aggregate_and_grouping_capabilities!
        structured = @model_class.columns_hash.values.filter_map do |column|
          next if @prohibited_fields.include?(column.name)
          next unless reflectable_column(column.name)

          reflected_field(column)
        end
        unless @aggregate_allowlist
          numeric = structured.select { |field| NUMERIC_TYPES.include?(field.type) }.map(&:name)
          ordered = structured.select { |field| ORDERED_TYPES.include?(field.type) }.map(&:name)
          @aggregates = {count: true, sum: numeric, average: numeric, minimum: ordered, maximum: ordered}
        end
        @aggregates = @aggregates.to_h do |function, permission|
          normalized = if function == :count && permission == true
            true
          elsif permission == true
            structured.select { |field| aggregate_compatible?(function, field.type) }.map(&:name)
          else
            Array(permission) & structured.map(&:name)
          end
          [function, normalized]
        end
        unless @grouping_allowlist
          @grouping = structured.select { |field| GROUPABLE_TYPES.include?(field.type) }.map(&:name)
        end
        @grouping &= structured.map(&:name)
        @grouping.freeze
      end

      def aggregate_compatible?(function, type)
        case function
        when :count then true
        when :sum, :average then NUMERIC_TYPES.include?(type.to_sym)
        when :minimum, :maximum then ORDERED_TYPES.include?(type.to_sym)
        else false
        end
      end

      def annotation_conflicts(description:, synonyms:, annotation:)
        return [] unless annotation

        conflicts = []
        conflicts << :description if description && annotation.key?(:description)
        conflicts << :synonyms if Array(synonyms).any? && annotation.key?(:synonyms)
        conflicts
      end

      def raise_annotation_conflict!(name, conflicts)
        raise ConfigurationError,
          "Conflicting field annotation for #{@model_class.name}.#{name}: #{conflicts.join(", ")}"
      end

      def raise_association_annotation_conflict!(name, conflicts)
        raise ConfigurationError,
          "Conflicting association annotation for #{@model_class.name}.#{name}: #{conflicts.join(", ")}"
      end

      def apply_field_annotations!
        @fields.map! do |field|
          annotation = @field_annotations[field.name]
          next field unless annotation

          Field.new(**field.to_h.merge(annotation))
        end
      end

      def apply_association_annotations!
        @associations.map! do |association|
          annotation = @association_annotations[association.name]
          next association unless annotation

          Association.new(**association.to_h.merge(annotation))
        end
      end

      def reflect_fields!
        @model_class.columns_hash.sort.each do |_name, column|
          next unless reflectable_column(column.name)

          @fields << reflected_field(column)
        end
      end

      def reflect_associations!
        @model_class.reflect_on_all_associations.sort_by { |reflection| reflection.name.to_s }.each do |reflection|
          @associations << Association.new(name: reflection.name)
        end
      end

      def reflectable_column(name)
        column = @model_class.columns_hash[name.to_s]
        column unless column && serialized_attribute?(column.name)
      end

      def reflected_field(column, description: nil, synonyms: [], enum_values: [], sensitive: false)
        unless column.type
          raise ConfigurationError,
            "Cannot reflect #{@model_class.name}.#{column.name}: Active Record reported no column type"
        end

        values = enum_values.empty? ? @model_class.defined_enums.fetch(column.name, {}).keys.sort : enum_values
        Field.new(name: column.name, type: column.type, null: column.null, description: description,
          synonyms: synonyms, enum_values: values, sensitive: sensitive)
      end

      def serialized_attribute?(name)
        defined?(ActiveRecord::Type::Serialized) &&
          @model_class.type_for_attribute(name).is_a?(ActiveRecord::Type::Serialized)
      end
    end
  end
end
