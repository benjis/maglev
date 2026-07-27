# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Maglev v0.3 public ask contract" do
  around do |example|
    original_policy_resolver = Maglev.configuration.policy_resolver
    original_selector = Maglev.configuration.resource_selector_adapter
    example.run
  ensure
    Maglev.configuration.policy_resolver = original_policy_resolver
    Maglev.configuration.resource_selector_adapter = original_selector
    Maglev::Registry.reset!
  end

  before do
    stub_const("PublicAskRecord", Class.new(ActiveRecord::Base) do
      self.table_name = "customers"

      maglev_resource :public_ask_records do
        knowledge { content :name }
      end
    end)
  end

  it "removes request-style v0.2 entry points without hiding lower-level retrieval" do
    record = PublicAskRecord.new
    relation = PublicAskRecord.all

    expect(Maglev).not_to respond_to(:request)
    expect(PublicAskRecord).not_to respond_to(:maglev_request)
    expect(relation).not_to respond_to(:maglev_request)
    expect(record).not_to respond_to(:ask)
    expect(record).not_to respond_to(:explain)
    expect(PublicAskRecord).to respond_to(:search, :retrieve, :ask)

    expect { Maglev.request("legacy") }
      .to raise_error(Maglev::ConfigurationError, /removed in v0\.3.*Maglev\.ask/)
    expect { PublicAskRecord.maglev_request("legacy") }
      .to raise_error(Maglev::ConfigurationError, /removed in v0\.3.*without a mode/)
    expect { relation.maglev_request("legacy") }
      .to raise_error(Maglev::ConfigurationError, /removed in v0\.3.*without a mode/)
    expect { record.ask("legacy") }
      .to raise_error(Maglev::ConfigurationError, /removed in v0\.3.*Maglev\.ask/)
    expect { record.explain }
      .to raise_error(Maglev::ConfigurationError, /removed in v0\.3.*Maglev\.ask/)
    expect { PublicAskRecord.ask("legacy", limit: 5) }
      .to raise_error(Maglev::ConfigurationError, /now uses the v0\.3 BusinessOutcome contract/)
  end

  it "gives model-scoped ask the same mode-free BusinessOutcome contract" do
    Maglev.configuration.policy_resolver = lambda do |user:, context:|
      {
        public_ask_records: {
          base_relation: PublicAskRecord.where(id: user),
          planning_facts: {locale: context}
        }
      }
    end
    Maglev.configuration.resource_selector_adapter = Maglev::FakeResourceSelectorAdapter.new([{
      "status" => "unsupported",
      "message" => "No authorized resource matches this question."
    }])

    outcome = PublicAskRecord.ask("What is the weather?", user: 1, context: "en-AU")

    expect(outcome).to be_a(Maglev::BusinessOutcome)
    expect(outcome).to have_attributes(status: :failed, answer: nil)
    expect(outcome.warnings).to eq(["The question could not be answered safely."])
  end
end
