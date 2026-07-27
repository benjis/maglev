# frozen_string_literal: true

require "rails_helper"
require "open3"

RSpec.describe "reload-safe dummy application boot" do
  it "exposes the same resource capabilities without application eager loading" do
    dummy_root = File.expand_path("../dummy", __dir__)
    command = [
      Gem.ruby,
      File.join(dummy_root, "bin/rails"),
      "runner",
      "puts Maglev::Registry.entries.map(&:identifier).join(',')"
    ]

    output, error, status = Open3.capture3(
      {"RAILS_ENV" => "test", "BUNDLE_GEMFILE" => File.expand_path("../../Gemfile", __dir__)},
      *command,
      chdir: dummy_root
    )

    expect(status).to be_success, error
    expect(output.split(",")).to include(
      "accounts",
      "customers",
      "orders",
      "products",
      "support_tickets"
    )
  end
end
