# frozen_string_literal: true

require "spec_helper"
require "maglev/indexer"

RSpec.describe "Owner id compatibility" do
  it "fails clearly for non-integer owner ids in the bigint v1 schema" do
    record = instance_double("UuidRecord", id: "f47ac10b-58cc-4372-a567-0e02b2c3d479")
    allow(record).to receive(:class).and_return(double(name: "UuidRecord"))

    expect do
      Maglev::Indexer.new(record).index
    end.to raise_error(Maglev::ConfigurationError, /bigint owner ids/)
  end
end
