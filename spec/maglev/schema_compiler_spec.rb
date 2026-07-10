# frozen_string_literal: true

require "rails_helper"
require "maglev/schema_compiler"
require "maglev/knowledge_config"

RSpec.describe Maglev::SchemaCompiler do
  around do |example|
    connection = ActiveRecord::Base.connection
    connection.create_table(:compiler_customers, force: true) do |t|
      t.string :name
    end
    connection.create_table(:compiler_tickets, force: true) do |t|
      t.string :subject
      t.references :compiler_customer
    end
    example.run
  ensure
    connection&.drop_table(:compiler_tickets, if_exists: true)
    connection&.drop_table(:compiler_customers, if_exists: true)
  end

  before do
    stub_const("CompilerCustomer", Class.new(ActiveRecord::Base) do
      self.table_name = "compiler_customers"
      has_many :tickets, class_name: "CompilerTicket", inverse_of: :customer, foreign_key: :compiler_customer_id
    end)
    stub_const("CompilerTicket", Class.new(ActiveRecord::Base) do
      self.table_name = "compiler_tickets"
      belongs_to :customer, class_name: "CompilerCustomer", inverse_of: :tickets, foreign_key: :compiler_customer_id
    end)
  end

  it "accepts declared belongs_to, has_one, and has_many associations with invertible dependencies" do
    ticket_config = Maglev::KnowledgeConfig.build(CompilerTicket) do
      expose :subject
    end
    allow(CompilerTicket).to receive(:maglev_config).and_return(ticket_config)
    config = Maglev::KnowledgeConfig.build(CompilerCustomer) do
      expose :name
      include_related :tickets, depth: 1, limit: 20
    end

    compiled = described_class.new(config).compile

    expect(compiled.relations.first.name).to eq("tickets")
    expect(compiled.relations.first.inverse).to eq("customer")
  end

  it "fails clearly for invalid associations" do
    config = Maglev::KnowledgeConfig.build(CompilerCustomer) do
      expose :name
      include_related :not_real, depth: 1, limit: 1
    end

    expect { described_class.new(config).compile }
      .to raise_error(Maglev::ConfigurationError, /Unknown Maglev association/)
  end

  it "fails clearly when the inverse needed for invalidation cannot be inferred" do
    CompilerCustomer.has_many :unidirectional_tickets,
      class_name: "CompilerTicket",
      foreign_key: :compiler_customer_id
    config = Maglev::KnowledgeConfig.build(CompilerCustomer) do
      expose :name
      include_related :unidirectional_tickets, depth: 1, limit: 1
    end
    ticket_config = Maglev::KnowledgeConfig.build(CompilerTicket) do
      expose :subject
    end
    allow(CompilerTicket).to receive(:maglev_config).and_return(ticket_config)

    expect { described_class.new(config).compile }
      .to raise_error(Maglev::ConfigurationError, /inverse/)
  end
end
