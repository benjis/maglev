# frozen_string_literal: true

module Maglev
  module VectorStores
    class Base
      def fetch(ids:)
        raise NotImplementedError, "#{self.class.name} must implement #fetch"
      end

      def upsert(documents:)
        raise NotImplementedError, "#{self.class.name} must implement #upsert"
      end

      def replace_owner(owner_type:, owner_id:, documents:)
        raise NotImplementedError, "#{self.class.name} must implement #replace_owner"
      end

      def search(vector:, filters:, limit:)
        raise NotImplementedError, "#{self.class.name} must implement #search"
      end

      def delete(ids:)
        raise NotImplementedError, "#{self.class.name} must implement #delete"
      end

      def delete_by_owner(owner_type:, owner_id:)
        raise NotImplementedError, "#{self.class.name} must implement #delete_by_owner"
      end

      def healthcheck
        raise NotImplementedError, "#{self.class.name} must implement #healthcheck"
      end

      def capabilities
        {}
      end
    end
  end
end
