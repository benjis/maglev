# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "standard/rake"
require_relative "lib/maglev"

load File.expand_path("lib/tasks/maglev.rake", __dir__)

RSpec::Core::RakeTask.new(:spec)

task default: %i[spec standard]
