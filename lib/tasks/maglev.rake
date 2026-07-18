# frozen_string_literal: true

namespace :maglev do
  desc "Inspect a built gem before release: rake maglev:release_audit[path]"
  task :release_audit, [:path] do |_task, args|
    require "rubygems/package"
    require "stringio"
    require "zlib"

    path = args[:path] || Dir[File.expand_path("../../pkg/maglev-rb-*.gem", __dir__)].max
    raise "built gem not found" unless path && File.file?(path)

    package = Gem::Package.new(path)
    specification = package.spec
    raise "gem version mismatch" unless specification.version.to_s == Maglev::VERSION

    files = []
    File.open(path, "rb") do |io|
      Gem::Package::TarReader.new(io) do |outer|
        outer.each do |entry|
          next unless entry.full_name == "data.tar.gz"

          Zlib::GzipReader.wrap(StringIO.new(entry.read)) do |gzip|
            Gem::Package::TarReader.new(gzip) { |inner| inner.each { |item| files << item.full_name } }
          end
        end
      end
    end
    forbidden = files.grep(%r{(?:^|/)(?:tmp|log|spec)/|AGENTS|IMPLEMENTATION_PLAN|TODO|local_secret})
    raise "forbidden packaged files: #{forbidden.join(", ")}" if forbidden.any?

    puts "Release audit passed: #{specification.name} #{specification.version} (#{files.size} files)"
  end

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

  desc "Score a provider-free Maglev planner evaluation corpus"
  task :evaluate_planner, [:path] do |_task, args|
    path = args[:path] || File.expand_path("../../spec/dummy/evaluations/planner_v1.json", __dir__)
    corpus = Maglev::PlannerEvaluation.load(path)
    report = Maglev::PlannerEvaluation.score(corpus.fetch("cases"))
    percentage = (report.fetch(:score) * 100).round(1)
    puts "Planner evaluation v#{corpus.fetch("version")}: #{report.fetch(:passed)}/#{report.fetch(:total)} passed (#{percentage}%)"
    report.fetch(:cases).reject { |item| item.fetch(:passed) }.each do |item|
      puts "- #{item.fetch(:id)}: #{item.fetch(:failure_class)}"
    end
  end
end
