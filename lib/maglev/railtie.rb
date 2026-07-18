# frozen_string_literal: true

require "rails/railtie"

module Maglev
  class Railtie < Rails::Railtie
    initializer "maglev.active_record_extension" do
      ActiveSupport.on_load(:active_record) do
        require "maglev/active_record_extension"

        include Maglev::ActiveRecordExtension
      end
    end

    initializer "maglev.reloader" do
      config.to_prepare do
        Maglev::DependencyGraph.reset!
        Maglev::KnowledgeRegistry.rebuild!
      end
    end

    rake_tasks do
      load "tasks/maglev.rake"
    end
  end
end
