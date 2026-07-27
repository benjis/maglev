# frozen_string_literal: true

require "rails_helper"

RSpec.describe Maglev::IndexGeneration do
  before do
    described_class.delete_all
  end

  it "keeps a completed generation inactive until an atomic cutover" do
    previous = described_class.create!(
      generation: "previous",
      status: "active",
      representation_version: Maglev::IndexIdentity::REPRESENTATION_VERSION,
      manifest: {"products" => "v3-previous"},
      expected_record_count: 2,
      indexed_record_count: 2,
      started_at: Time.now.utc,
      completed_at: Time.now.utc,
      activated_at: Time.now.utc
    )
    candidate = described_class.start!(
      generation: "candidate",
      representation_version: Maglev::IndexIdentity::REPRESENTATION_VERSION,
      manifest: {"products" => "v3-candidate"},
      expected_record_count: 2
    )

    candidate.record_indexed!
    candidate.record_indexed!
    candidate.complete!

    expect(described_class.active).to eq(previous)
    expect(candidate.reload.status).to eq("completed")

    candidate.cutover!(current_manifest: candidate.manifest)

    expect(described_class.active).to eq(candidate)
    expect(previous.reload.status).to eq("obsolete")
  end

  it "rejects incomplete and incompatible generations without changing the active generation" do
    active = described_class.create!(
      generation: "active",
      status: "active",
      representation_version: Maglev::IndexIdentity::REPRESENTATION_VERSION,
      manifest: {"products" => "v3-active"},
      expected_record_count: 1,
      indexed_record_count: 1,
      started_at: Time.now.utc,
      completed_at: Time.now.utc,
      activated_at: Time.now.utc
    )
    incomplete = described_class.start!(
      generation: "incomplete",
      representation_version: Maglev::IndexIdentity::REPRESENTATION_VERSION,
      manifest: {"products" => "v3-incomplete"},
      expected_record_count: 1
    )
    incompatible = described_class.create!(
      generation: "incompatible",
      status: "completed",
      representation_version: "maglev-knowledge-v9",
      manifest: {"products" => "v9-incompatible"},
      expected_record_count: 1,
      indexed_record_count: 1,
      started_at: Time.now.utc,
      completed_at: Time.now.utc
    )

    expect { incomplete.cutover!(current_manifest: incomplete.manifest) }
      .to raise_error(Maglev::IndexGeneration::InvalidCutover)
    expect { incompatible.cutover!(current_manifest: incompatible.manifest) }
      .to raise_error(Maglev::IndexGeneration::InvalidCutover)
    expect(described_class.active).to eq(active)
  end

  it "records failure without replacing the active generation" do
    active = described_class.create!(
      generation: "active",
      status: "active",
      representation_version: Maglev::IndexIdentity::REPRESENTATION_VERSION,
      manifest: {"products" => "v3-active"},
      expected_record_count: 1,
      indexed_record_count: 1,
      started_at: Time.now.utc,
      completed_at: Time.now.utc,
      activated_at: Time.now.utc
    )
    candidate = described_class.start!(
      generation: "candidate",
      representation_version: Maglev::IndexIdentity::REPRESENTATION_VERSION,
      manifest: {"products" => "v3-candidate"},
      expected_record_count: 1
    )

    candidate.fail!(RuntimeError.new("embedding failed"))

    expect(candidate.reload.status).to eq("failed")
    expect(candidate.failure_class).to eq("RuntimeError")
    expect(described_class.active).to eq(active)
  end

  it "identifies obsolete generations without deleting them" do
    obsolete = described_class.create!(
      generation: "old",
      status: "obsolete",
      representation_version: Maglev::IndexIdentity::REPRESENTATION_VERSION,
      manifest: {},
      expected_record_count: 0,
      indexed_record_count: 0,
      started_at: Time.now.utc,
      completed_at: Time.now.utc
    )

    expect(described_class.obsolete).to contain_exactly(obsolete)
    expect { described_class.obsolete }.not_to change(described_class, :count)
  end

  it "aborts an interrupted build without changing the active generation" do
    candidate = described_class.start!(
      generation: "interrupted",
      representation_version: Maglev::IndexIdentity::REPRESENTATION_VERSION,
      manifest: {},
      expected_record_count: 1
    )

    expect(described_class.stale_builds(before: 1.minute.from_now)).to contain_exactly(candidate)

    candidate.abort!

    expect(candidate.reload).to have_attributes(status: "failed", failure_class: "InterruptedRebuild")
  end

  it "does not classify a long-running build with a recent heartbeat as stale" do
    candidate = described_class.start!(
      generation: "progressing",
      representation_version: Maglev::IndexIdentity::REPRESENTATION_VERSION,
      manifest: {},
      expected_record_count: 2
    )
    candidate.update_column(:updated_at, 2.hours.ago)

    candidate.heartbeat!

    expect(described_class.stale_builds(before: 1.hour.ago)).to be_empty
  end
end
