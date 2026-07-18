# frozen_string_literal: true

module Maglev
  module VectorStores
    class MetadataFilter
      include Enumerable

      FIELDS = %i[owner_type owner_id owner_ids owner_model_name tenant_id source_type source_types index_version].freeze
      SOURCE_TYPES = %i[snapshot attribute related_record rich_text attachment tag].freeze
      MAX_VALUES = 1_000

      def self.coerce(value)
        value.is_a?(self) ? value : new(**value.to_h)
      end

      def initialize(**values)
        unknown = values.keys.map(&:to_sym) - FIELDS
        raise ArgumentError, "Unsupported metadata filter: #{unknown.join(", ")}" if unknown.any?

        normalized = values.transform_keys(&:to_sym)
        validate!(normalized)
        @values = normalized.transform_values { |value| value.is_a?(Array) ? value.dup.freeze : value }.freeze
        freeze
      end

      def each(&block) = @values.each(&block)
      def to_h = @values
      def fetch(...) = @values.fetch(...)
      def key?(key) = @values.key?(key)

      private

      def validate!(values)
        %i[owner_ids source_types].each do |field|
          next unless values.key?(field)
          value = values[field]
          raise ArgumentError, "#{field} must be a non-empty Array" unless value.is_a?(Array) && value.any?
          raise ArgumentError, "#{field} exceeds #{MAX_VALUES} values" if value.size > MAX_VALUES
        end
        Array(values[:source_type]).each { |value| validate_source_type!(value) } if values.key?(:source_type)
        Array(values[:source_types]).each { |value| validate_source_type!(value) } if values.key?(:source_types)
        %i[owner_type owner_model_name tenant_id index_version].each do |field|
          next unless values.key?(field)
          raise ArgumentError, "#{field} must be a non-empty String" unless values[field].is_a?(String) && !values[field].empty?
        end
      end

      def validate_source_type!(value)
        return if SOURCE_TYPES.include?(value.to_sym)

        raise ArgumentError, "Unsupported source type: #{value.inspect}"
      end
    end
  end
end
