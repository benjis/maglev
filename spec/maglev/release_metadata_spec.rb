# frozen_string_literal: true

require "spec_helper"

RSpec.describe "release metadata" do
  subject(:specification) { Gem::Specification.load(File.expand_path("../../maglev.gemspec", __dir__)) }

  it "packages version 0.1.1 as maglev-rb while preserving the Maglev require path" do
    expect(specification.name).to eq("maglev-rb")
    expect(specification.version.to_s).to eq("0.1.1")
    expect(specification.require_paths).to eq(["lib"])
    expect(specification.files).to include("lib/maglev.rb")
    expect(specification.files).not_to include("AGENTS.md")
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
end
