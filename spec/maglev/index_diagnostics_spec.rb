# frozen_string_literal: true

require "rails_helper"
require "maglev/index_diagnostics"

RSpec.describe Maglev::IndexDiagnostics do
  around do |example|
    connection = ActiveRecord::Base.connection
    connection.create_table(:maglev_index_states, force: true) do |t|
      t.string :owner_type, null: false
      t.bigint :owner_id, null: false
      t.string :status, null: false
      t.string :active_index_version
      t.integer :chunk_count, null: false, default: 0
      t.datetime :last_success_at
      t.string :latest_failure_class
      t.datetime :latest_failure_at
      t.boolean :rebuild_required, null: false, default: false
      t.timestamps
    end
    connection.add_index :maglev_index_states, [:owner_type, :owner_id], unique: true
    Maglev::IndexState.reset_column_information
    example.run
  ensure
    connection&.drop_table(:maglev_index_states, if_exists: true)
  end

  it "reports indexing success and safe failure diagnostics" do
    described_class.record_success(owner_type: "Product", owner_id: 7, index_version: "v2", chunk_count: 3)
    described_class.record_failure(owner_type: "Product", owner_id: 7, index_version: "v2", error: RuntimeError.new("secret"))

    state = described_class.status(owner_type: "Product", owner_id: 7)
    expect(state).to have_attributes(status: :failed, active_index_version: "v2", chunk_count: 3, rebuild_required: true)
    expect(state.latest_failure).to include(error_class: "RuntimeError")
    expect(state.latest_failure.to_s).not_to include("secret")
  end

  it "reports active rebuilds and clears state after unindex" do
    described_class.record_success(owner_type: "Product", owner_id: 8, index_version: "v1", chunk_count: 2)
    described_class.record_started(owner_type: "Product", owner_id: 8, index_version: "v2")
    expect(described_class.status(owner_type: "Product", owner_id: 8)).to have_attributes(status: :rebuilding, rebuild_required: true)

    described_class.record_unindexed(owner_type: "Product", owner_id: 8)
    expect(described_class.status(owner_type: "Product", owner_id: 8)).to have_attributes(status: :not_indexed, chunk_count: 0, rebuild_required: false)
  end
end
