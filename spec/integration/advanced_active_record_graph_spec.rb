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
