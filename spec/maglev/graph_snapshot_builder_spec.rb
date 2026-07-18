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

class GraphSnapshotNode
  attr_accessor :id, :name, :children

  def self.name = "GraphSnapshotNode"
  def self.attribute_names = %w[id name]

  def self.maglev_config
    @maglev_config ||= Maglev::KnowledgeConfig.build(self) do
      expose :name
      include_related :children, depth: 2, limit: 1, inverse: :parent
    end
  end
end

RSpec.describe Maglev::SnapshotBuilder do
  around do |example|
    original = Maglev.configuration
    Maglev.instance_variable_set(:@configuration, Maglev::Configuration.new)
    example.run
  ensure
    Maglev.instance_variable_set(:@configuration, original)
  end

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

  it "truncates a related subtree through the builder and records its relation path" do
    Maglev.configuration.snapshot_related_record_max_characters = 35
    customer = GraphSnapshotCustomer.new
    customer.id = 1
    customer.name = "Acme"
    ticket = GraphSnapshotTicket.new
    ticket.id = 10
    ticket.subject = "Urgent renewal risk"
    customer.tickets = [ticket]
    customer.account = nil

    snapshot = described_class.new(customer, GraphSnapshotCustomer.maglev_config).build

    expect(snapshot.metadata[:sources]).to include(
      include(kind: :related_record, path: "tickets[0]", original_characters: be > 35, retained_characters: 35)
    )
    expect(snapshot.to_s).not_to include("Urgent renewal risk")
  end

  it "terminates cycles through visited-record protection" do
    first_node = GraphSnapshotNode.new
    first_node.id = 1
    first_node.name = "First"
    second_node = GraphSnapshotNode.new
    second_node.id = 2
    second_node.name = "Second"
    first_node.children = [second_node]
    second_node.children = [first_node]

    snapshot = described_class.new(first_node, GraphSnapshotNode.maglev_config).build.to_s

    expect(snapshot.scan("GraphSnapshotNode#1").size).to eq(1)
    expect(snapshot.scan("GraphSnapshotNode#2").size).to eq(1)
  end

  it "stops after the direct record when a relation has depth one" do
    first_customer = GraphSnapshotCustomer.new
    first_customer.id = 1
    first_customer.name = "First"
    first_ticket = GraphSnapshotTicket.new
    first_ticket.id = 10
    first_ticket.subject = "Direct"
    second_customer = GraphSnapshotCustomer.new
    second_customer.id = 2
    second_customer.name = "Must not be traversed"
    second_ticket = GraphSnapshotTicket.new
    second_ticket.id = 11
    second_ticket.subject = "Also too deep"
    first_customer.tickets = [first_ticket]
    first_ticket.customer = second_customer
    second_customer.tickets = [second_ticket]
    second_ticket.customer = first_customer

    snapshot = described_class.new(first_customer, GraphSnapshotCustomer.maglev_config).build.to_s

    expect(snapshot).to include("tickets[0].subject: Direct")
    expect(snapshot).not_to include("Must not be traversed")
    expect(snapshot).not_to include("Also too deep")
  end

  it "uses a relation depth as the subtree hop budget" do
    root = GraphSnapshotNode.new
    root.id = 1
    root.name = "Root"
    child = GraphSnapshotNode.new
    child.id = 2
    child.name = "Child"
    grandchild = GraphSnapshotNode.new
    grandchild.id = 3
    grandchild.name = "Grandchild"
    great_grandchild = GraphSnapshotNode.new
    great_grandchild.id = 4
    great_grandchild.name = "Too deep"
    root.children = [child]
    child.children = [grandchild]
    grandchild.children = [great_grandchild]
    great_grandchild.children = []

    snapshot = described_class.new(root, GraphSnapshotNode.maglev_config).build.to_s

    expect(snapshot).to include("children[0].name: Child")
    expect(snapshot).to include("children[0].children[0].name: Grandchild")
    expect(snapshot).not_to include("Too deep")
  end

  it "uses the global maximum as a hard hop ceiling" do
    original_max_depth = Maglev.configuration.max_relation_depth
    Maglev.configuration.max_relation_depth = 1
    root = GraphSnapshotNode.new
    root.id = 1
    root.name = "Root"
    child = GraphSnapshotNode.new
    child.id = 2
    child.name = "Child"
    grandchild = GraphSnapshotNode.new
    grandchild.id = 3
    grandchild.name = "Too deep globally"
    root.children = [child]
    child.children = [grandchild]
    grandchild.children = []

    snapshot = described_class.new(root, GraphSnapshotNode.maglev_config).build.to_s

    expect(snapshot).to include("children[0].name: Child")
    expect(snapshot).not_to include("Too deep globally")
  ensure
    Maglev.configuration.max_relation_depth = original_max_depth
  end
end
