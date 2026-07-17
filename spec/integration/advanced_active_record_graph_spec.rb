# frozen_string_literal: true

require "rails_helper"
require "active_job/test_helper"

RSpec.describe "Advanced ActiveRecord graph support" do
  include ActiveJob::TestHelper

  around do |example|
    connection = ActiveRecord::Base.connection
    connection.create_table(:advanced_graph_customers, force: true) do |t|
      t.string :name
      t.timestamps
    end
    connection.create_table(:advanced_graph_tickets, force: true) do |t|
      t.string :subject
      t.references :advanced_graph_customer
      t.timestamps
    end
    connection.create_table(:advanced_graph_groups, force: true) do |t|
      t.string :name
      t.timestamps
    end
    connection.create_table(:advanced_graph_memberships, force: true) do |t|
      t.references :advanced_graph_customer
      t.references :advanced_graph_group
      t.string :role
      t.timestamps
    end
    connection.create_table(:advanced_graph_events, force: true) do |t|
      t.string :message
      t.references :eventable, polymorphic: true
      t.timestamps
    end
    example.run
  ensure
    clear_enqueued_jobs
    clear_performed_jobs
    connection&.drop_table(:advanced_graph_events, if_exists: true)
    connection&.drop_table(:advanced_graph_memberships, if_exists: true)
    connection&.drop_table(:advanced_graph_groups, if_exists: true)
    connection&.drop_table(:advanced_graph_tickets, if_exists: true)
    connection&.drop_table(:advanced_graph_customers, if_exists: true)
  end

  before do
    ActiveJob::Base.queue_adapter = :test
    stub_const("AdvancedGraphTicket", Class.new(ActiveRecord::Base) do
      self.table_name = "advanced_graph_tickets"
      belongs_to :customer, class_name: "AdvancedGraphCustomer", inverse_of: :tickets, foreign_key: :advanced_graph_customer_id
    end)
    stub_const("AdvancedGraphMembership", Class.new(ActiveRecord::Base) do
      self.table_name = "advanced_graph_memberships"
      belongs_to :customer, class_name: "AdvancedGraphCustomer", inverse_of: :memberships, foreign_key: :advanced_graph_customer_id
      belongs_to :group, class_name: "AdvancedGraphGroup", inverse_of: :memberships, foreign_key: :advanced_graph_group_id
    end)
    stub_const("AdvancedGraphGroup", Class.new(ActiveRecord::Base) do
      self.table_name = "advanced_graph_groups"
      has_many :memberships, class_name: "AdvancedGraphMembership", inverse_of: :group, foreign_key: :advanced_graph_group_id
      has_many :customers, through: :memberships, source: :customer
    end)
    stub_const("AdvancedGraphEvent", Class.new(ActiveRecord::Base) do
      self.table_name = "advanced_graph_events"
      belongs_to :eventable, polymorphic: true
    end)
    stub_const("AdvancedGraphCustomer", Class.new(ActiveRecord::Base) do
      self.table_name = "advanced_graph_customers"
      has_many :tickets, class_name: "AdvancedGraphTicket", inverse_of: :customer, foreign_key: :advanced_graph_customer_id
      has_many :memberships, class_name: "AdvancedGraphMembership", inverse_of: :customer, foreign_key: :advanced_graph_customer_id
      has_many :groups, through: :memberships, source: :group
      has_many :events, as: :eventable, class_name: "AdvancedGraphEvent"
    end)

    AdvancedGraphTicket.has_knowledge do
      expose :subject
    end
    AdvancedGraphGroup.has_knowledge do
      expose :name
    end
    AdvancedGraphEvent.has_knowledge do
      expose :message
    end
    AdvancedGraphCustomer.has_knowledge do
      expose :name
      include_related :tickets, depth: 1, limit: 10
      include_related :groups, depth: 1, limit: 10, inverse: :customers
      include_related :events, depth: 1, limit: 10, inverse: :eventable
    end
  end

  it "includes has_many through and polymorphic related knowledge without flattening join model fields" do
    customer = AdvancedGraphCustomer.create!(name: "Acme")
    group = AdvancedGraphGroup.create!(name: "Renewal risk cohort")
    AdvancedGraphMembership.create!(customer: customer, group: group, role: "owner-only metadata")
    AdvancedGraphEvent.create!(eventable: customer, message: "Escalation logged")

    snapshot = customer.maglev_snapshot

    expect(snapshot).to include("groups[0].name: Renewal risk cohort")
    expect(snapshot).to include("events[0].message: Escalation logged")
    expect(snapshot).not_to include("owner-only metadata")
  end

  it "orders and limits an unloaded collection association in SQL" do
    AdvancedGraphCustomer.has_knowledge do
      expose :name
      include_related :tickets, depth: 1, limit: 2
    end
    customer = AdvancedGraphCustomer.create!(name: "Acme")
    AdvancedGraphTicket.create!(id: 30, customer: customer, subject: "Third")
    AdvancedGraphTicket.create!(id: 10, customer: customer, subject: "First")
    AdvancedGraphTicket.create!(id: 20, customer: customer, subject: "Second")
    customer = AdvancedGraphCustomer.find(customer.id)
    queries = []

    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      queries << payload[:sql] if payload[:sql].include?(%("advanced_graph_tickets"))
    end
    snapshot = customer.maglev_snapshot
    ActiveSupport::Notifications.unsubscribe(subscriber)

    expect(snapshot).to include("tickets[0].subject: First")
    expect(snapshot).to include("tickets[1].subject: Second")
    expect(snapshot).not_to include("Third")
    expect(queries.one?).to be(true)
    expect(queries.first).to match(/ORDER BY .*advanced_graph_tickets.*id.*ASC/i)
    expect(queries.first).to match(/LIMIT (?:2|\$\d+)\z/i)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it "preserves unsaved records from a loaded collection association" do
    AdvancedGraphCustomer.has_knowledge do
      expose :name
      include_related :tickets, depth: 1, limit: 3
    end
    customer = AdvancedGraphCustomer.create!(name: "Acme")
    customer.tickets.create!(id: 30, subject: "Third")
    customer.tickets.create!(id: 10, subject: "First")
    customer.tickets.load
    customer.tickets.target.reverse!
    customer.tickets.build(subject: "Draft")

    snapshot = customer.maglev_snapshot

    expect(snapshot).to include("tickets[0].subject: First")
    expect(snapshot).to include("tickets[1].subject: Third")
    expect(snapshot).to include("tickets[2].subject: Draft")
  end

  it "uses the same primary-key order for loaded and unloaded collection associations" do
    AdvancedGraphCustomer.has_knowledge do
      expose :name
      include_related :tickets, depth: 1, limit: 2
    end
    customer = AdvancedGraphCustomer.create!(name: "Acme")
    AdvancedGraphTicket.create!(id: 30, customer: customer, subject: "Third")
    AdvancedGraphTicket.create!(id: 10, customer: customer, subject: "First")
    AdvancedGraphTicket.create!(id: 20, customer: customer, subject: "Second")

    unloaded_snapshot = AdvancedGraphCustomer.find(customer.id).maglev_snapshot
    loaded_customer = AdvancedGraphCustomer.find(customer.id)
    loaded_customer.tickets.load
    loaded_customer.tickets.target.reverse!

    expect(loaded_customer.maglev_snapshot).to eq(unloaded_snapshot)
  end

  it "preserves explicit association order for a loaded collection" do
    AdvancedGraphCustomer.has_many :tickets,
      -> { order(id: :desc) },
      class_name: "AdvancedGraphTicket",
      inverse_of: :customer,
      foreign_key: :advanced_graph_customer_id
    AdvancedGraphCustomer.has_knowledge do
      expose :name
      include_related :tickets, depth: 1, limit: 2
    end
    customer = AdvancedGraphCustomer.create!(name: "Acme")
    AdvancedGraphTicket.create!(id: 30, customer: customer, subject: "Third")
    AdvancedGraphTicket.create!(id: 10, customer: customer, subject: "First")
    AdvancedGraphTicket.create!(id: 20, customer: customer, subject: "Second")
    customer.tickets.load

    snapshot = customer.maglev_snapshot

    expect(snapshot).to include("tickets[0].subject: Third")
    expect(snapshot).to include("tickets[1].subject: Second")
    expect(snapshot).not_to include("First")
  end

  it "reindexes both previous and current owners when a direct related record is reassigned" do
    old_customer = AdvancedGraphCustomer.create!(name: "Old")
    new_customer = AdvancedGraphCustomer.create!(name: "New")
    ticket = AdvancedGraphTicket.create!(customer: old_customer, subject: "Move me")
    clear_enqueued_jobs

    ticket.update!(customer: new_customer)

    expect(enqueued_reindex_args).to include(["AdvancedGraphCustomer", old_customer.id])
    expect(enqueued_reindex_args).to include(["AdvancedGraphCustomer", new_customer.id])
  end

  it "reindexes polymorphic owners when polymorphic related records change" do
    customer = AdvancedGraphCustomer.create!(name: "Acme")
    event = AdvancedGraphEvent.create!(eventable: customer, message: "Initial")
    clear_enqueued_jobs

    event.update!(message: "Changed")

    expect(enqueued_reindex_args).to include(["AdvancedGraphCustomer", customer.id])
  end

  def enqueued_reindex_args
    enqueued_jobs.filter_map { |job| job[:args] if job[:job] == Maglev::ReindexJob }
  end
end
