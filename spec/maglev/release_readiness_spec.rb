# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Maglev release readiness" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:specification) { Gem::Specification.load(File.join(root, "maglev.gemspec")) }

  it "keeps package version metadata consistent" do
    expect(specification.version.to_s).to eq(Maglev::VERSION)
  end

  it "ships the canonical documentation" do
    expect(specification.files).to include("README.md", "CHANGELOG.md")
  end

  it "records the v0.3 compatibility and reindex transition" do
    upgrade = File.read(File.join(root, "docs/UPGRADING_V0_3.md"))

    expect(upgrade).to include(
      "No backward compatibility",
      "maglev_request",
      "Maglev.request",
      "mode:",
      "queryable",
      "expose",
      "Maglev.ask",
      "full reindex",
      "activate_index_generation!"
    )
  end

  it "excludes specifications, tickets, plans, logs, temporary data, and secrets from the package" do
    excluded = specification.files.grep(
      %r{(?:^|/)(?:tmp|log|spec|specifications|\.scratch)/|AGENTS|IMPLEMENTATION_PLAN|TODO|local_secret}
    )

    expect(excluded).to be_empty
  end
end
