# frozen_string_literal: true

require "json"

module Maglev
  class ResourceCatalog
    def initialize(max_resources: Maglev.configuration.resource_catalog_max_resources,
      max_bytes: Maglev.configuration.resource_catalog_max_bytes)
      @max_resources = max_resources
      @max_bytes = max_bytes
    end

    def build(authorized_identifiers)
      identifiers = authorized_identifiers.map(&:to_s).uniq.sort
      raise ConfigurationError, "authorized resource catalog exceeds #{@max_resources} resources" if identifiers.length > @max_resources

      summaries = identifiers.map do |identifier|
        entry = Registry.fetch(identifier)
        {
          identifier: entry.identifier,
          description: entry.description.to_s,
          synonyms: entry.synonyms,
          structured: !entry.queryable.nil?,
          knowledge: !entry.knowledge.nil?
        }.freeze
      end.freeze
      raise ConfigurationError, "authorized resource catalog exceeds #{@max_bytes} bytes" if JSON.generate(summaries).bytesize > @max_bytes

      summaries
    end
  end
end
