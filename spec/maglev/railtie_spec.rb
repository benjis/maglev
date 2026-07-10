# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Maglev Railtie" do
  it "loads through the dummy Rails application" do
    expect(defined?(Maglev::Railtie)).to eq("constant")
    expect(Rails.application.railties).to include(Maglev::Railtie.instance)
  end

  it "does not define a Rails Engine" do
    expect(defined?(Maglev::Engine)).to be_nil
    expect(Maglev::Railtie < Rails::Engine).to be_nil
  end
end
