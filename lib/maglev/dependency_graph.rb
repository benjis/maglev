# frozen_string_literal: true

require_relative "reindex_job"

module Maglev
  class DependencyGraph
    Edge = Struct.new(:owner_class, :related_class, :relation_name, :inverse)

    class << self
      def register(schema)
        schema.relations.each do |relation|
          edge = Edge.new(schema.model_class, relation.related_class, relation.name, relation.inverse)
          next if edges_for(relation.related_class).any? { |existing| same_edge?(existing, edge) }

          edges_for(relation.related_class) << edge
          install_callbacks(relation.related_class)
        end
      end

      def reindex_dependents_for(record)
        dependent_owners = previous_dependent_owners(record)
        edges_for(record.class).each do |edge|
          dependent_owners.concat(owners_for(record, edge))
        end

        dependent_owners.uniq { |owner| [owner.class.name, owner.id] }.each do |owner|
          next unless owner.respond_to?(:id) && owner.id

          ReindexJob.perform_later(owner.class.name, owner.id)
        end
        record.remove_instance_variable(:@maglev_previous_dependent_owners) if record.instance_variable_defined?(:@maglev_previous_dependent_owners)
      end

      def capture_previous_dependents_for(record)
        owners = edges_for(record.class).flat_map { |edge| previous_owners_for(record, edge) }
        record.instance_variable_set(:@maglev_previous_dependent_owners, owners)
      end

      private

      def edges
        @edges ||= Hash.new { |hash, klass| hash[klass] = [] }
      end

      def edges_for(klass)
        edges[klass]
      end

      def same_edge?(left, right)
        left.owner_class == right.owner_class &&
          left.related_class == right.related_class &&
          left.relation_name == right.relation_name &&
          left.inverse == right.inverse
      end

      def install_callbacks(klass)
        unless klass.method_defined?(:maglev_reindex_dependents)
          klass.class_eval do
            def maglev_capture_previous_dependents
              Maglev::DependencyGraph.capture_previous_dependents_for(self)
            end

            def maglev_reindex_dependents
              Maglev::DependencyGraph.reindex_dependents_for(self)
            end
          end
        end

        unless klass._update_callbacks.any? { |callback| callback.filter == :maglev_capture_previous_dependents }
          klass.before_update :maglev_capture_previous_dependents
        end

        unless klass._destroy_callbacks.any? { |callback| callback.filter == :maglev_capture_previous_dependents }
          klass.before_destroy :maglev_capture_previous_dependents
        end

        return if klass._commit_callbacks.any? { |callback| callback.filter == :maglev_reindex_dependents }

        klass.after_commit :maglev_reindex_dependents, on: %i[create update destroy]
      end

      def owners_for(record, edge)
        owners = record.public_send(edge.inverse)
        if owners.respond_to?(:find_each)
          owners.to_a
        elsif owners.respond_to?(:to_ary)
          owners.to_ary
        else
          [owners].compact
        end
      end

      def previous_dependent_owners(record)
        if record.instance_variable_defined?(:@maglev_previous_dependent_owners)
          record.instance_variable_get(:@maglev_previous_dependent_owners)
        else
          []
        end
      end

      def previous_owners_for(record, edge)
        inverse_reflection = record.class.reflect_on_association(edge.inverse.to_sym)
        return owners_for(record, edge) unless inverse_reflection&.belongs_to?

        previous_owner_for_belongs_to(record, edge, inverse_reflection)
      end

      def previous_owner_for_belongs_to(record, edge, reflection)
        old_id = attribute_in_database(record, reflection.foreign_key)
        return [] unless old_id

        if reflection.polymorphic?
          old_type = attribute_in_database(record, reflection.foreign_type)
          return [] unless old_type == edge.owner_class.name
        end

        [edge.owner_class.find_by(id: old_id)].compact
      end

      def attribute_in_database(record, attribute)
        if record.respond_to?(:attribute_in_database)
          record.attribute_in_database(attribute)
        else
          record.public_send(attribute)
        end
      end
    end
  end
end
