# frozen_string_literal: true

require_relative "resource_config"
require_relative "schema_snapshot"

module Maglev
  class Registry
    class << self
      def register(entry)
        mutex.synchronize do
          @entries ||= {}
          existing = @entries[entry.identifier]
          if existing && existing.model_class != entry.model_class && existing.model_class.name != entry.model_class.name
            raise ConfigurationError, "Maglev resource #{entry.identifier} is already registered"
          end
          @entries[entry.identifier] = entry
          @snapshot_cache = {}
        end
        entry
      end

      def fetch(identifier)
        mutex.synchronize { (@entries || {})[identifier.to_s] }
      end

      def entries
        mutex.synchronize { (@entries || {}).values.sort_by(&:identifier).freeze }
      end

      def snapshot(resources:, user: nil, authorizer: nil, limits: {})
        identifiers = Array(resources).map(&:to_s).uniq.sort
        selected = identifiers.filter_map { |identifier| fetch(identifier) }.select(&:queryable)
        selected.select! do |entry|
          entry.queryable.authorization == :public || authorizer&.call(entry, user)
        end

        cache_key = [identifiers, limits.sort].freeze if user.nil? && authorizer.nil?
        mutex.synchronize { return @snapshot_cache[cache_key] if cache_key && @snapshot_cache&.key?(cache_key) }

        result = SchemaSnapshot::Builder.new(selected, limits: limits).build
        mutex.synchronize { (@snapshot_cache ||= {})[cache_key] = result } if cache_key
        result
      end

      def invalidate!
        mutex.synchronize { @snapshot_cache = {} }
      end

      def reset!
        mutex.synchronize do
          @entries = {}
          @snapshot_cache = {}
        end
      end

      def rebuild!
        reset!
        KnowledgeRegistry.model_names.each do |model_name|
          model = model_name.safe_constantize
          model.rebuild_maglev_registry_registration if model&.respond_to?(:rebuild_maglev_registry_registration)
        end
        invalidate!
      end

      private

      def mutex
        @mutex ||= Mutex.new
      end
    end
  end
end
