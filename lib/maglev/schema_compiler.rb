# frozen_string_literal: true

require_relative "configuration"
require_relative "errors"

module Maglev
  class SchemaCompiler
    SUPPORTED_MACROS = %i[belongs_to has_one has_many].freeze

    CompiledSchema = Struct.new(:model_class, :relations)
    CompiledRelation = Struct.new(:name, :depth, :limit, :inverse, :macro, :related_class)

    def initialize(config, max_depth: Maglev.configuration.max_relation_depth)
      @config = config
      @max_depth = max_depth
    end

    def compile
      CompiledSchema.new(@config.model_class, @config.relations.map { |relation| compile_relation(relation) }.freeze)
    end

    private

    def compile_relation(relation)
      reflection = @config.model_class.reflect_on_association(relation.name.to_sym)
      unless reflection
        raise ConfigurationError, "Unknown Maglev association #{@config.model_class.name}.#{relation.name}"
      end

      unless SUPPORTED_MACROS.include?(reflection.macro)
        raise ConfigurationError, "Unsupported Maglev association #{@config.model_class.name}.#{relation.name}: #{reflection.macro}"
      end

      if relation.depth > @max_depth
        raise ConfigurationError, "Maglev association #{@config.model_class.name}.#{relation.name} exceeds maximum depth #{@max_depth}"
      end

      related_class = reflection.klass
      unless related_class.respond_to?(:maglev_config) && related_class.maglev_config
        raise ConfigurationError, "Related Maglev model #{related_class.name} must declare has_knowledge"
      end

      inverse = relation.inverse || reflection.inverse_of&.name&.to_s
      unless inverse && related_class.reflect_on_association(inverse.to_sym)
        raise ConfigurationError, "Maglev association #{@config.model_class.name}.#{relation.name} requires an inverse for invalidation"
      end

      CompiledRelation.new(relation.name, relation.depth, relation.limit, inverse, reflection.macro, related_class)
    end
  end
end
