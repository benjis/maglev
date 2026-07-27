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

      def load_application_models!
        return unless defined?(Rails.application) && Rails.application
        return unless model_names.empty?

        models_path = Rails.application.root.join("app/models")
        return unless models_path.directory?

        mutex.synchronize do
          load_condition.wait(mutex) while @application_models_loading
          return if @application_models_loaded

          @application_models_loading = true
        end

        loaded = false
        begin
          Rails.autoloaders.main.eager_load_dir(models_path)
          loaded = true
        ensure
          mutex.synchronize do
            @application_models_loaded = loaded
            @application_models_loading = false
            load_condition.broadcast
          end
        end
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

      def load_condition
        @load_condition ||= ConditionVariable.new
      end
    end
  end
end
