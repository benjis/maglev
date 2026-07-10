# frozen_string_literal: true

require "spec_helper"
require "maglev"

RSpec.describe Maglev do
  it "yields the configuration shell" do
    yielded = nil

    described_class.configure do |config|
      yielded = config
    end

    expect(yielded).to be_a(Maglev::Configuration)
    expect(yielded).to be(described_class.configuration)
  end
end
