# frozen_string_literal: true

require "rails_helper"

RSpec.describe "ActiveRecord answering integration" do
  before do
    stub_const("AnswerableCustomer", Class.new(ActiveRecord::Base) do
      def self.attribute_names
        %w[id name description]
      end
    end)
  end

  it "exposes class-level ask through Maglev::Answerer" do
    answerer = instance_double(Maglev::Answerer, ask: "response")
    allow(Maglev::Answerer).to receive(:new).with(AnswerableCustomer).and_return(answerer)

    expect(AnswerableCustomer.ask("Who is at risk?", limit: 4)).to eq("response")
    expect(answerer).to have_received(:ask).with("Who is at risk?", limit: 4)
  end

  it "exposes instance-level ask scoped to the receiver" do
    customer = AnswerableCustomer.allocate
    answerer = instance_double(Maglev::Answerer, ask: "response")
    allow(Maglev::Answerer).to receive(:new).with(AnswerableCustomer).and_return(answerer)

    expect(customer.ask("Why unhappy?", limit: 2)).to eq("response")
    expect(answerer).to have_received(:ask).with("Why unhappy?", limit: 2, owner: customer)
  end

  it "uses the configured default question for explain" do
    customer = AnswerableCustomer.allocate
    answerer = instance_double(Maglev::Answerer, ask: "response")
    allow(Maglev.configuration).to receive(:explain_question).and_return("Explain this record.")
    allow(Maglev::Answerer).to receive(:new).with(AnswerableCustomer).and_return(answerer)

    expect(customer.explain(limit: 1)).to eq("response")
    expect(answerer).to have_received(:ask).with("Explain this record.", limit: 1, owner: customer)
  end
end
