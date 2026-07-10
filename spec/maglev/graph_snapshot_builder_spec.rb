# frozen_string_literal: true

require "spec_helper"
require "maglev/knowledge_config"
require "maglev/snapshot_builder"

class GraphSnapshotCustomer
  attr_accessor :id, :name, :tickets, :account

  def self.name = "GraphSnapshotCustomer"
  def self.attribute_names = %w[id name]

  def self.maglev_config
    @maglev_config ||= Maglev::KnowledgeConfig.build(self) do
      expose :name
      include_related :tickets, depth: 1, limit: 1, inverse: :customer
      include_related :account, depth: 1, limit: 1, inverse: :customer
    end
  end
end

class GraphSnapshotTicket
  attr_accessor :id, :subject, :customer

  def self.name = "GraphSnapshotTicket"
  def self.attribute_names = %w[id subject]

  def self.maglev_config
    @maglev_config ||= Maglev::KnowledgeConfig.build(self) do
      expose :subject
      include_related :customer, depth: 1, limit: 1, inverse: :tickets
    end
  end
end

class GraphSnapshotAccount
  attr_accessor :id, :status, :customer

  def self.name = "GraphSnapshotAccount"
  def self.attribute_names = %w[id status]

  def self.maglev_config
    @maglev_config ||= Maglev::KnowledgeConfig.build(self) do
      expose :status
    end
  end
end

RSpec.describe Maglev::SnapshotBuilder do
  it "includes related exposed fields with stable relation-path labels and relation limits" do
    customer = GraphSnapshotCustomer.new
    customer.id = 1
    customer.name = "Acme"
    first_ticket = GraphSnapshotTicket.new
    first_ticket.id = 10
    first_ticket.subject = "Urgent renewal risk"
    second_ticket = GraphSnapshotTicket.new
    second_ticket.id = 11
    second_ticket.subject = "Should be limited out"
    account = GraphSnapshotAccount.new
    account.id = 20
    account.status = "delinquent"
    customer.tickets = [first_ticket, second_ticket]
    customer.account = account
    first_ticket.customer = customer

    snapshot = described_class.new(customer, GraphSnapshotCustomer.maglev_config).build.to_s

    expect(snapshot).to eq(<<~TEXT.chomp)
      GraphSnapshotCustomer#1
      name: Acme
      tickets[0] GraphSnapshotTicket#10
      tickets[0].subject: Urgent renewal risk
      account GraphSnapshotAccount#20
      account.status: delinquent
    TEXT
  end

  it "terminates cycles through visited-record protection" do
    customer = GraphSnapshotCustomer.new
    customer.id = 1
    customer.name = "Acme"
    ticket = GraphSnapshotTicket.new
    ticket.id = 10
    ticket.subject = "Loops back"
    customer.tickets = [ticket]
    ticket.customer = customer

    snapshot = described_class.new(customer, GraphSnapshotCustomer.maglev_config).build.to_s

    expect(snapshot.scan("GraphSnapshotCustomer#1").size).to eq(1)
    expect(snapshot).to include("tickets[0].subject: Loops back")
  end
end
