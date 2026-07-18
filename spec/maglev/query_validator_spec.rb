# frozen_string_literal: true

require "spec_helper"
require "maglev/query_validator"

RSpec.describe Maglev::QueryValidator do
  let(:customer) do
    Maglev::SchemaSnapshot::Resource.new(
      identifier: "customers", description: nil, synonyms: [], table_name: "customers", primary_key: "id",
      sti_base: "customers", inheritance_column: "type",
      fields: [Maglev::SchemaSnapshot::Field.new(name: "name", type: :string, null: false, enum_values: [], description: nil, synonyms: [])],
      associations: [], scopes: [], aggregates: {}, limits: {}, allow_unscoped_model_queries: false
    )
  end
  let(:orders) do
    Maglev::SchemaSnapshot::Resource.new(
      identifier: "orders", description: nil, synonyms: [], table_name: "orders", primary_key: "id",
      sti_base: "orders", inheritance_column: "type",
      fields: [
        Maglev::SchemaSnapshot::Field.new(name: "status", type: :string, null: false, enum_values: %w[paid pending], description: nil, synonyms: []),
        Maglev::SchemaSnapshot::Field.new(name: "note", type: :string, null: true, enum_values: [], description: nil, synonyms: []),
        Maglev::SchemaSnapshot::Field.new(name: "total", type: :decimal, null: false, enum_values: [], description: nil, synonyms: []),
        Maglev::SchemaSnapshot::Field.new(name: "created_at", type: :datetime, null: false, enum_values: [], description: nil, synonyms: [])
      ],
      associations: [Maglev::SchemaSnapshot::Association.new(name: "customer", resource: "customers", macro: :belongs_to, polymorphic: false, description: nil, synonyms: [])],
      scopes: [{name: "placed_during", description: nil, parameters: {"from" => {type: :date, required: true, nullable: false, enum_values: [], minimum: nil, maximum: nil}}}],
      aggregates: {count: true, sum: ["total"], average: ["total"], minimum: ["total"], maximum: ["total"]},
      limits: {rows: 50, operations: 30, joins: 2}, allow_unscoped_model_queries: false
    )
  end
  let(:snapshot) { Maglev::SchemaSnapshot.new(resources: [orders, customer], paths: ["orders.customer"]) }
  let(:validator) { described_class.new(snapshot: snapshot, root: :orders) }
  let(:input) do
    {
      "version" => 1, "root" => "orders", "operation" => "records",
      "scopes" => [{"name" => "placed_during", "parameters" => {"from" => "2026-07-01"}}],
      "filters" => [{"field" => "status", "operator" => "eq", "value" => "paid"}],
      "joins" => ["customer"], "sort" => [{"field" => "created_at", "direction" => "desc"}],
      "distinct" => false, "limit" => 25
    }
  end

  it "produces immutable typed IR with stable JSON round trips and a deterministic explanation" do
    result = validator.call(input)

    expect(result).to be_valid
    expect(result.ir).to be_frozen
    expect(result.ir.filters.first.value.value).to eq("paid")
    expect(Maglev::QueryIR.from_json(result.ir.to_json).to_h).to eq(result.ir.to_h)
    expect(result.explanation).to eq("Select records from orders; apply scope placed_during; filter status eq; join customer; sort created_at desc; limit 25")
  end

  it "accepts aggregates, joined paths, boundaries, and explicit relative time values" do
    aggregate = input.merge("operation" => "aggregate", "aggregate" => {"function" => "sum", "field" => "total"}, "limit" => 50)
    aggregate.delete("sort")
    aggregate["filters"] = [
      {"field" => "customer.name", "operator" => "eq", "value" => "Ada"},
      {"field" => "created_at", "operator" => "gte", "value" => {"relative" => {"amount" => 7, "unit" => "days", "direction" => "ago"}}}
    ]

    result = validator.call(aggregate)

    expect(result).to be_valid
    expect(result.ir.aggregate.function).to eq(:sum)
    expect(result.ir.filters.last.value).to be_a(Maglev::QueryIR::RelativeTime)
  end

  it "fails closed for unknown keys, hostile fragments, model switching, bad enums, and ambiguous times" do
    attacks = [
      input.merge("sql" => "DROP TABLE orders"),
      input.merge("root" => "customers"),
      input.merge("filters" => [{"field" => "status", "operator" => "eq", "value" => "deleted"}]),
      input.merge("filters" => [{"field" => "created_at", "operator" => "gte", "value" => "last week"}]),
      input.merge("operation" => "delete")
    ]

    attacks.each do |attack|
      result = validator.call(attack)
      expect(result).not_to be_valid
      expect(result.errors).not_to be_empty
      expect(result.errors.flat_map(&:details).join).not_to include("DROP TABLE", "last week")
    end
  end

  it "validates operator/type shapes, nullability, scopes, aggregate permission, and limits" do
    invalid_inputs = [
      input.merge("filters" => [{"field" => "total", "operator" => "in", "value" => 1}]),
      input.merge("filters" => [{"field" => "total", "operator" => "is_null"}]),
      input.merge("scopes" => [{"name" => "missing", "parameters" => {}}]),
      input.merge("operation" => "aggregate", "aggregate" => {"function" => "maximum", "field" => "status"}),
      input.merge("limit" => 51),
      input.merge("joins" => %w[customer customer customer])
    ]

    invalid_inputs.each { |candidate| expect(validator.call(candidate)).not_to be_valid }
  end

  it "covers every predicate and aggregate operation at its accepted boundary" do
    predicates = {
      "eq" => "paid", "not_eq" => "paid", "gt" => 1, "gte" => 1, "lt" => 10, "lte" => 10,
      "in" => %w[paid pending], "not_in" => ["paid"], "between" => [1, 10]
    }
    predicates.each do |operator, value|
      field = %w[eq not_eq in not_in].include?(operator) ? "status" : "total"
      expect(validator.call(input.merge("filters" => [{"field" => field, "operator" => operator, "value" => value}]))).to be_valid
    end
    %w[is_null is_not_null].each do |operator|
      expect(validator.call(input.merge("filters" => [{"field" => "note", "operator" => operator}]))).to be_valid
    end
    %w[count sum average minimum maximum].each do |function|
      aggregate = {"function" => function}
      aggregate["field"] = "total" unless function == "count"
      candidate = input.merge("operation" => "aggregate", "aggregate" => aggregate)
      expect(validator.call(candidate)).to be_valid
    end

    absolute_time = input.merge("filters" => [{"field" => "created_at", "operator" => "gte", "value" => "2026-07-18T10:00:00+10:00"}])
    expect(validator.call(absolute_time)).to be_valid
  end

  it "rejects malformed and non-JSON input without raising or querying a provider/database" do
    [nil, [], {version: 1}, {"version" => Float::INFINITY}, {"version" => 1, "root" => "orders", "operation" => "records", "filters" => [Object.new]}].each do |value|
      expect { expect(validator.call(value)).not_to be_valid }.not_to raise_error
    end
  end
end
