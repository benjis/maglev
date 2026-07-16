# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

RSpec.describe "provider adapter require boundaries" do
  it "loads adapters and their direct consumers without requiring maglev first" do
    lib_path = File.expand_path("../../lib", __dir__)
    require_paths = %w[
      maglev/adapters/faraday_embedding
      maglev/adapters/faraday_generation
      maglev/indexer
      maglev/retriever
      maglev/answerer
    ]

    require_paths.each do |require_path|
      _stdout, stderr, status = Open3.capture3(
        RbConfig.ruby,
        "-I#{lib_path}",
        "-e",
        "require #{require_path.inspect}"
      )

      expect(status).to be_success, "failed to require #{require_path}:\n#{stderr}"
    end
  end
end
