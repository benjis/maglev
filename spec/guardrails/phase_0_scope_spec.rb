# frozen_string_literal: true

require "spec_helper"

RSpec.describe "phase scope guardrails" do
  it "does not include post-Phase 2 production files" do
    forbidden_paths = [
      "app/controllers",
      "app/models/maglev",
      "app/jobs/maglev",
      "config/routes.rb",
      "db/migrate",
      "lib/maglev/generation_adapter.rb",
      "lib/maglev/context_assembler.rb",
      "lib/maglev/response.rb"
    ]

    existing_forbidden_paths = forbidden_paths.select { |path| File.exist?(File.expand_path("../../#{path}", __dir__)) }

    expect(existing_forbidden_paths).to be_empty
  end

  it "does not depend on generation-only libraries" do
    gemspec = Gem::Specification.load(File.expand_path("../../maglev.gemspec", __dir__))
    dependency_names = gemspec.dependencies.map(&:name)

    expect(dependency_names).not_to include("ruby-openai")
  end

  it "does not define later-phase answer APIs" do
    require "maglev"
    require "maglev/active_record_extension"

    expect(Maglev.singleton_methods).not_to include(:ask, :explain)
    expect(Maglev::ActiveRecordExtension.instance_methods).not_to include(:ask, :explain)
    expect(Maglev::ActiveRecordExtension::ClassMethods.instance_methods).not_to include(:ask)
  end
end
