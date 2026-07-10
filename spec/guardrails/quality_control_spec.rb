# frozen_string_literal: true

RSpec.describe "quality control guardrails" do
  it "requires RuboCop in dependencies, CI, and completion instructions" do
    gemspec = Gem::Specification.load(File.expand_path("../../maglev.gemspec", __dir__))
    dependency_names = gemspec.dependencies.map(&:name)
    ci_config = File.read(File.expand_path("../../.github/workflows/ci.yml", __dir__))
    agent_instructions = File.read(File.expand_path("../../AGENTS.md", __dir__))

    expect(dependency_names).to include("rubocop")
    expect(File).to exist(File.expand_path("../../.rubocop.yml", __dir__))
    expect(ci_config).to include("bundle exec rubocop")
    expect(agent_instructions).to include("bundle exec rubocop")
  end
end
