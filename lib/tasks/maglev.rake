# frozen_string_literal: true

namespace :maglev do
  desc "Reindex one Maglev model: rails maglev:reindex[ModelName]"
  task :reindex, [:model_name] => :environment do |_task, args|
    model_name = args[:model_name]
    raise ArgumentError, "Usage: rails maglev:reindex[ModelName]" if model_name.nil? || model_name.empty?

    model = model_name.constantize
    model.find_each { |record| Maglev::Indexer.new(record).index }
  end

  desc "Reindex all configured Maglev models"
  task reindex_all: :environment do
    ActiveRecord::Base.descendants.each do |model|
      next unless model.respond_to?(:maglev_config) && model.maglev_config

      model.find_each { |record| Maglev::Indexer.new(record).index }
    end
  end

  desc "Show configured Maglev models"
  task status: :environment do
    models = ActiveRecord::Base.descendants.select { |model| model.respond_to?(:maglev_config) && model.maglev_config }
    puts "Maglev configured models:"
    models.each do |model|
      schema = model.maglev_schema
      puts "- #{schema.fetch(:model)} fields=#{schema.fetch(:exposed_attributes).join(",")}"
    end
  end
end
