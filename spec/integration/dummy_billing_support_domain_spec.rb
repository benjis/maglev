# frozen_string_literal: true

require "rails_helper"

RSpec.describe "dummy billing and support reference domain" do
  it "registers billing and support resources without exposing sensitive fields" do
    expect([Account, Invoice, SupportTicket]).to all(be < ApplicationRecord)
    invoice = Maglev::Registry.fetch(:invoices)
    ticket = Maglev::Registry.fetch(:support_tickets)

    expect(invoice.queryable.fields.map(&:name)).to contain_exactly("status", "amount", "due_on", "paid_at")
    expect(invoice.queryable.prohibited_fields).to include("internal_note")
    expect(ticket.queryable.fields.map(&:name)).to contain_exactly("status", "priority", "created_at")
    expect(ticket.knowledge.exposed_attributes).to contain_exactly("subject", "body", "status", "priority")
  end

  it "uses an account-owned base relation as the tenant authority boundary" do
    suffix = SecureRandom.hex(4)
    first = Account.create!(name: "First", tenant_key: "tenant-one-#{suffix}")
    second = Account.create!(name: "Second", tenant_key: "tenant-two-#{suffix}")
    visible = first.invoices.create!(number: "INV-1", status: "open", amount: 25, due_on: Date.current)
    second.invoices.create!(number: "INV-2", status: "open", amount: 900, due_on: Date.current)

    snapshot = Maglev::Registry.snapshot(resources: [:invoices], authorizer: ->(*) { true })
    validation = Maglev::QueryValidator.new(snapshot: snapshot, root: :invoices).call(
      "version" => 1,
      "root" => "invoices",
      "operation" => "records",
      "filters" => [{"field" => "status", "operator" => "eq", "value" => "open"}],
      "limit" => 10
    )
    expect(validation.errors).to be_empty
    plan = Maglev::QueryCompiler.new(snapshot: snapshot).compile(
      validation: validation,
      base_relation: first.invoices
    )

    expect(Maglev::StructuredExecutor.new.execute(plan).map(&:id)).to eq([visible.id])
  end
end
