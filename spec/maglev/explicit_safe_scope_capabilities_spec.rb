# frozen_string_literal: true

require "rails_helper"

RSpec.describe "explicit safe scope capabilities" do
  around do |example|
    connection = ActiveRecord::Base.connection
    connection.create_table(:scope_capability_records, force: true) do |table|
      table.integer :tenant_id, null: false
      table.string :status, null: false
      table.datetime :deleted_at
    end
    example.run
  ensure
    connection&.drop_table(:scope_capability_records, if_exists: true)
  end

  before do
    stub_const("ScopeCapabilityRecord", Class.new(ActiveRecord::Base) do
      self.table_name = "scope_capability_records"

      default_scope { where(deleted_at: nil) }
      scope :with_status, ->(status = "active") { where(status: status) }
      scope :with_deleted, -> { unscope(where: :deleted_at) }
      scope :unsupported_result, -> { [] }
      scope :wrong_model, -> { AlternateScopeCapabilityRecord.all }
      scope :raises_error, -> { raise "scope failure" }
    end)
    stub_const("AlternateScopeCapabilityRecord", Class.new(ActiveRecord::Base) do
      self.table_name = "scope_capability_records"
    end)

    Maglev::Registry.reset!
  end

  after { Maglev::Registry.reset! }

  it "does not infer Active Record scopes into the authorized schema" do
    ScopeCapabilityRecord.maglev_resource :scope_capability_records do
      queryable { authorization :public }
    end

    snapshot = Maglev::Registry.snapshot(resources: [:scope_capability_records])
    resource = snapshot.resources.fetch(0)

    expect(resource.scopes).to be_empty
    expect(validate(snapshot, "with_status", "status" => "active")).not_to be_valid
  end

  it "allows an omitted optional trailing parameter to use the declared scope default" do
    ScopeCapabilityRecord.maglev_resource :scope_capability_records do
      queryable do
        scope :with_status, parameters: {status: {type: :string}}
        authorization :public
      end
    end
    visible = ScopeCapabilityRecord.create!(tenant_id: 1, status: "active")
    ScopeCapabilityRecord.create!(tenant_id: 1, status: "archived")
    ScopeCapabilityRecord.create!(tenant_id: 2, status: "active")

    snapshot = Maglev::Registry.snapshot(resources: [:scope_capability_records])
    validation = Maglev::QueryValidator.new(snapshot: snapshot, root: :scope_capability_records).call(
      "version" => 2,
      "root" => "scope_capability_records",
      "operation" => "records",
      "scopes" => [{"name" => "with_status", "parameters" => {}}],
      "filters" => [],
      "joins" => [],
      "sort" => [],
      "distinct" => false,
      "limit" => 10
    )

    plan = Maglev::QueryCompiler.new(snapshot: snapshot).compile(
      validation: validation,
      base_relation: ScopeCapabilityRecord.where(tenant_id: 1)
    )

    expect(plan.relation.pluck(:id)).to eq([visible.id])
  end

  it "rejects an ambiguous positional contract with a required parameter after an optional one" do
    expect do
      ScopeCapabilityRecord.maglev_resource :scope_capability_records do
        queryable do
          scope :with_status, parameters: {
            optional_status: {type: :string},
            required_status: {type: :string, required: true}
          }
        end
      end
    end.to raise_error(
      Maglev::ConfigurationError,
      /Required scope parameters must precede optional parameters/
    )
  end

  it "rejects a gap in supplied optional positional parameters during validation" do
    register_scope :with_status, parameters: {
      first: {type: :string},
      second: {type: :string}
    }
    snapshot = Maglev::Registry.snapshot(resources: [:scope_capability_records])

    validation = validate(snapshot, "with_status", "second" => "active")

    expect(validation).not_to be_valid
    expect(validation.errors.map(&:message)).to include(
      "Scope parameters must be provided in declaration order without gaps"
    )
  end

  it "publishes and validates the bounded typed parameter contract" do
    register_scope :with_status, parameters: {
      status: {type: :string, required: true, enum_values: %w[active archived]}
    }
    snapshot = Maglev::Registry.snapshot(resources: [:scope_capability_records])

    expect(snapshot.resources.fetch(0).scopes).to eq([
      {
        name: "with_status",
        description: nil,
        parameters: {
          "status" => {
            type: :string,
            required: true,
            nullable: false,
            enum_values: %w[active archived],
            minimum: nil,
            maximum: nil
          }
        }
      }
    ])
    expect(validate(snapshot, "with_status", "status" => "unknown")).not_to be_valid
  end

  it "rejects a declared deleted-record scope before executing the query" do
    register_scope :with_deleted
    visible = ScopeCapabilityRecord.create!(tenant_id: 1, status: "active")
    ScopeCapabilityRecord.unscoped.create!(
      tenant_id: 1,
      status: "active",
      deleted_at: Time.current
    )
    snapshot = Maglev::Registry.snapshot(resources: [:scope_capability_records])
    validation = validate(snapshot, "with_deleted")

    expect do
      compile(snapshot, validation)
    end.to raise_error(Maglev::QueryCompilationError, /remove relation constraints/)

    expect(ScopeCapabilityRecord.where(tenant_id: 1).pluck(:id)).to eq([visible.id])
  end

  it "rejects a declared scope with an unsupported return type before query execution" do
    register_scope :unsupported_result
    snapshot = Maglev::Registry.snapshot(resources: [:scope_capability_records])
    validation = validate(snapshot, "unsupported_result")

    expect do
      compile(snapshot, validation)
    end.to raise_error(Maglev::QueryCompilationError, /incompatible relation/)
  end

  it "rejects a declared scope that switches models" do
    register_scope :wrong_model
    snapshot = Maglev::Registry.snapshot(resources: [:scope_capability_records])

    expect do
      compile(snapshot, validate(snapshot, "wrong_model"))
    end.to raise_error(Maglev::QueryCompilationError, /incompatible relation/)
  end

  it "normalizes application scope failures as safe compilation errors" do
    register_scope :raises_error
    snapshot = Maglev::Registry.snapshot(resources: [:scope_capability_records])

    expect do
      compile(snapshot, validate(snapshot, "raises_error"))
    end.to raise_error(
      Maglev::QueryCompilationError,
      /Registered scope could not be applied safely: RuntimeError/
    )
  end

  def register_scope(name, parameters: {})
    ScopeCapabilityRecord.maglev_resource :scope_capability_records do
      queryable do
        scope name, parameters: parameters
        authorization :public
      end
    end
  end

  def validate(snapshot, name, parameters = {})
    Maglev::QueryValidator.new(snapshot: snapshot, root: :scope_capability_records).call(
      "version" => 2,
      "root" => "scope_capability_records",
      "operation" => "records",
      "scopes" => [{"name" => name, "parameters" => parameters}],
      "filters" => [],
      "joins" => [],
      "sort" => [],
      "distinct" => false,
      "limit" => 10
    )
  end

  def compile(snapshot, validation)
    Maglev::QueryCompiler.new(snapshot: snapshot).compile(
      validation: validation,
      base_relation: ScopeCapabilityRecord.where(tenant_id: 1)
    )
  end
end
