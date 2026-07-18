# frozen_string_literal: true

require "spec_helper"
require "maglev"
require "maglev/active_record_extension"

class DxRecord
  include Maglev::ActiveRecordExtension

  attr_accessor :id, :name

  def self.name = "DxRecord"
  def self.attribute_names = %w[id name]

  def self.after_commit(*)
  end

  maglev_resource :dx_records do
    knowledge do
      expose :name
    end
  end
end

RSpec.describe "Developer experience APIs" do
  it "exposes schema introspection for configured models" do
    schema = DxRecord.maglev_schema

    expect(schema).to include(
      model: "DxRecord",
      exposed_attributes: ["name"],
      relations: [],
      attached_sources: [],
      rich_text_sources: []
    )
  end

  it "builds a provider-free context preview" do
    record = DxRecord.new
    record.id = 7
    record.name = "Acme"

    preview = record.maglev_context_preview(question: "Who?")

    expect(preview.text).to include("DxRecord#7")
    expect(preview.metadata).to include(question: "Who?", provider_calls: 0)
  end
end
