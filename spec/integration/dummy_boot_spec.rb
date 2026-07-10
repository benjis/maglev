# frozen_string_literal: true

require "rails_helper"

RSpec.describe "dummy Rails app" do
  it "boots in test mode" do
    expect(Rails.env).to eq("test")
    expect(Rails.application).to be_a(Dummy::Application)
  end
end
