# frozen_string_literal: true

require "rails_helper"

RSpec.describe "dummy Rails app" do
  it "boots in test mode" do
    expect(Rails.env).to eq("test")
    expect(Rails.application).to be_a(Dummy::Application)
  end

  it "keeps the checked-in chunk schema aligned with fresh installs" do
    schema = File.read(File.expand_path("../dummy/db/schema.rb", __dir__))
    chunks = schema.match(/create_table "maglev_chunks".*?^  end$/m).to_s

    expect(chunks).to include('t.string "index_version", limit: 64, null: false')
  end
end
