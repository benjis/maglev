# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Maglev release readiness" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:specification) { Gem::Specification.load(File.join(root, "maglev.gemspec")) }

  it "keeps the MVP version and changelog release heading consistent" do
    changelog = File.read(File.join(root, "CHANGELOG.md"))

    expect(Maglev::VERSION).to eq("0.2.1")
    expect(specification.version.to_s).to eq(Maglev::VERSION)
    expect(changelog).to include("## [0.2.1] - 2026-07-21")
    expect(changelog).to include("Upgrade from 0.1.x")
  end

  it "ships canonical documentation while marking Japanese review as pending" do
    expect(specification.files).to include("README.md", "README.zh-CN.md", "README.ja.md", "CHANGELOG.md")
    expect(File.read(File.join(root, "README.md"))).to include("## Structured queries")
    expect(File.read(File.join(root, "README.zh-CN.md"))).to include("## 结构化查询")
    expect(File.read(File.join(root, "README.ja.md"))).to include("## Structured query")
    expect(File.read(File.join(root, "README.ja.md"))).to include("Technical translation review pending")
    expect(File.read(File.join(root, "README.ja.md"))).to include("英語版 [README.md](README.md) が正本")
  end

  it "records traceable MVP capabilities and release gates in shipped documentation" do
    readme = File.read(File.join(root, "README.md"))
    changelog = File.read(File.join(root, "CHANGELOG.md"))

    expect(readme).to include("Structured", "RAG", "Hybrid", "release_audit")
    expect(changelog).to include("Query IR v1", "Upgrade from 0.1.x")
  end

  it "excludes repository plans, logs, temporary data, and secrets from the package" do
    excluded = specification.files.grep(%r{(?:^|/)(?:tmp|log)/|AGENTS|IMPLEMENTATION_PLAN|TODO|local_secret})

    expect(excluded).to be_empty
    expect(specification.files).to be_none { |path| path.start_with?("spec/") }
  end
end
