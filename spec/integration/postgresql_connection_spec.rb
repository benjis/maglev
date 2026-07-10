# frozen_string_literal: true

require "rails_helper"

RSpec.describe "PostgreSQL connectivity" do
  it "executes a smoke query through ActiveRecord" do
    result = ActiveRecord::Base.connection.select_value("SELECT 1")

    expect(result).to eq(1)
  rescue ActiveRecord::ConnectionNotEstablished, PG::Error
    raise if ENV["MAGLEV_REQUIRE_POSTGRESQL"] == "true"

    skip "PostgreSQL is not available; CI requires this smoke test against a PostgreSQL service"
  end
end
