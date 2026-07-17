# frozen_string_literal: true

require_relative "lib/maglev/version"

Gem::Specification.new do |spec|
  spec.name = "maglev-rb"
  spec.version = Maglev::VERSION
  spec.authors = ["Maglev contributors"]

  spec.summary = "Rails-native semantic knowledge layer for ActiveRecord object graphs."
  spec.description = "Maglev adds semantic search and grounded RAG to ActiveRecord object graphs."
  spec.homepage = "https://github.com/benjis/maglev"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(__dir__) do
    Dir[
      "LICENSE.txt",
      "README.md",
      "README.zh-CN.md",
      "lib/**/*.rb",
      "lib/**/*.rake",
      "docs/**/*.md"
    ] - Dir["docs/superpowers/**/*.md"]
  end
  spec.require_paths = ["lib"]

  spec.add_dependency "neighbor", "~> 0.6"
  spec.add_dependency "rails", ">= 7.1", "< 9.0"
  spec.add_dependency "faraday", "~> 2.0"

  spec.add_development_dependency "pg", "~> 1.5"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rubocop", "~> 1.87"
  spec.add_development_dependency "rspec-rails", "~> 7.0"
  spec.add_development_dependency "standard", "~> 1.44"
end
