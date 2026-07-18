# frozen_string_literal: true

require "active_support/core_ext/string/inflections"

module Maglev
  class KnowledgeRegistry
    class << self
      def register(model_name)
        mutex.synchronize do
          @model_names ||= []
          @model_names << model_name.to_s unless @model_names.include?(model_name.to_s)
        end
      end

      def model_names
        mutex.synchronize { (@model_names || []).dup.freeze }
      end

      def rebuild!
        model_names.each do |model_name|
          model = model_name.safe_constantize
          model.rebuild_maglev_registration if model&.respond_to?(:rebuild_maglev_registration)
        end
      end

      private

      def mutex
        @mutex ||= Mutex.new
      end
    end
  end
end
