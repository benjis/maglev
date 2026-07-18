# frozen_string_literal: true

require "spec_helper"

RSpec.describe "release metadata" do
  subject(:specification) { Gem::Specification.load(File.expand_path("../../maglev.gemspec", __dir__)) }

  it "packages version 0.2.0 as maglev-rb while preserving the Maglev require path" do
    expect(specification.name).to eq("maglev-rb")
    expect(specification.version.to_s).to eq("0.2.0")
    expect(specification.require_paths).to eq(["lib"])
    expect(specification.files).to include("lib/maglev.rb")
    expect(specification.files).not_to include("AGENTS.md")
    expect(specification.files).to be_none { |path| path.start_with?("docs/superpowers/") }
    expect(specification.dependencies.map(&:name)).to include("faraday")
    expect(specification.dependencies.map(&:name)).not_to include("ruby_llm")
  end

  it "links the package to its public source repository without placeholder contacts" do
    expect(specification.homepage).to eq("https://github.com/benjis/maglev")
    expect(specification.metadata).to include(
      "homepage_uri" => "https://github.com/benjis/maglev",
      "source_code_uri" => "https://github.com/benjis/maglev",
      "rubygems_mfa_required" => "true"
    )
    expect(Array(specification.email)).not_to include("maintainers@example.com")
  end

  it "supports Ruby 3.3 and newer" do
    expect(specification.required_ruby_version).to be_satisfied_by(Gem::Version.new("3.3.0"))
    expect(specification.required_ruby_version).not_to be_satisfied_by(Gem::Version.new("3.2.11"))
  end

  it "does not ship RubyLLM runtime integration" do
    runtime_source = Dir[File.expand_path("../../lib/**/*.rb", __dir__)].to_h do |path|
      [path, File.read(path)]
    end

    expect(runtime_source.values.join("\n")).not_to match(/ruby_llm|RubyLLM/)
  end
end
