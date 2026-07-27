# frozen_string_literal: true

require "rails_helper"

class RebuildRecord
  attr_reader :id, :name

  def self.name = "RebuildRecord"
  def self.attribute_names = %w[id name]
  def self.maglev_resource_identifier = "rebuild_records"
  def self.maglev_config = (@maglev_config ||= Maglev::KnowledgeConfig.build(self) { content :name })
  def self.count = records.count
  def self.find_each(&block) = records.each(&block)
  def self.records = (@records ||= [])

  def initialize(id, name)
    @id = id
    @name = name
  end

  def maglev_snapshot = name
end

class RebuildEmbedding
  def initialize(fail_on: nil)
    @calls = 0
    @fail_on = fail_on
  end

  def maglev_adapter_id = "test.rebuild"
  def maglev_adapter_version = "1"

  def embed(_text)
    @calls += 1
    raise Maglev::PermanentProviderError, "failed" if @calls == @fail_on

    [1.0, 0.0]
  end
end

RebuildRegistryEntry = Data.define(:identifier, :model_class, :knowledge)

RSpec.describe Maglev::IndexRebuilder do
  before do
    Maglev::IndexGeneration.delete_all
    RebuildRecord.records.replace([RebuildRecord.new(1, "first"), RebuildRecord.new(2, "second")])
    allow(Maglev::Registry).to receive(:entries).and_return(
      [RebuildRegistryEntry.new(identifier: "rebuild_records", model_class: RebuildRecord, knowledge: true)]
    )
  end

  after do
    Maglev::IndexGeneration.delete_all
  end

  it "builds a complete isolated generation without activating it" do
    store = Maglev::VectorStores::Memory.new

    generation = described_class.new(
      resources: [RebuildRecord],
      vector_store: store,
      embedding_adapter: RebuildEmbedding.new,
      embedding_dimensions: 2,
      generation: "candidate"
    ).rebuild!

    expect(generation.status).to eq("completed")
    expect(generation.indexed_record_count).to eq(2)
    expect(generation.manifest.fetch("rebuild_records")).to include(
      "representation_version" => Maglev::IndexIdentity::REPRESENTATION_VERSION
    )
    expect(store.search(vector: [1.0, 0.0], filters: {generation: "candidate"}, limit: 10).map(&:content))
      .to contain_exactly("first", "second")
    expect(Maglev::IndexGeneration.active).to be_nil
  end

  it "exposes rebuild, inspection, and explicit activation through Maglev" do
    store = Maglev::VectorStores::Memory.new

    generation = Maglev.rebuild_index!(
      resources: [RebuildRecord],
      vector_store: store,
      embedding_adapter: RebuildEmbedding.new,
      embedding_dimensions: 2,
      generation: "public-candidate"
    )

    expect(Maglev.index_generation("public-candidate")).to eq(generation)
    expect(Maglev.active_index_generation).to be_nil

    Maglev.activate_index_generation!(
      "public-candidate",
      embedding_adapter: RebuildEmbedding.new,
      embedding_dimensions: 2
    )

    expect(Maglev.active_index_generation).to eq(generation.reload)
  end

  it "records a failed rebuild and leaves the active generation unchanged" do
    active = Maglev::IndexGeneration.create!(
      generation: "active",
      status: "active",
      representation_version: Maglev::IndexIdentity::REPRESENTATION_VERSION,
      manifest: {},
      expected_record_count: 0,
      indexed_record_count: 0,
      started_at: Time.now.utc,
      completed_at: Time.now.utc,
      activated_at: Time.now.utc
    )

    expect do
      described_class.new(
        resources: [RebuildRecord],
        vector_store: Maglev::VectorStores::Memory.new,
        embedding_adapter: RebuildEmbedding.new(fail_on: 2),
        embedding_dimensions: 2,
        generation: "failed-candidate"
      ).rebuild!
    end.to raise_error(Maglev::PermanentProviderError)

    failed = Maglev::IndexGeneration.find_by!(generation: "failed-candidate")
    expect(failed.status).to eq("failed")
    expect(failed.indexed_record_count).to eq(1)
    expect(Maglev::IndexGeneration.active).to eq(active)
  end

  it "keeps reads on the active generation until cutover" do
    store = Maglev::VectorStores::Memory.new
    adapter = RebuildEmbedding.new
    active = described_class.new(
      resources: [RebuildRecord],
      vector_store: store,
      embedding_adapter: adapter,
      embedding_dimensions: 2,
      generation: "active"
    ).rebuild!
    active.cutover!(current_manifest: active.manifest)
    RebuildRecord.records.replace([RebuildRecord.new(1, "updated first"), RebuildRecord.new(2, "updated second")])
    candidate = described_class.new(
      resources: [RebuildRecord],
      vector_store: store,
      embedding_adapter: adapter,
      embedding_dimensions: 2,
      generation: "candidate"
    ).rebuild!
    retriever = Maglev::Retriever.new(
      RebuildRecord,
      vector_store: store,
      embedding_adapter: adapter,
      embedding_dimensions: 2
    )

    expect(retriever.search("query", limit: 10).map(&:content)).to contain_exactly("first", "second")

    candidate.cutover!(current_manifest: candidate.manifest)

    expect(retriever.search("query", limit: 10).map(&:content))
      .to contain_exactly("updated first", "updated second")
    expect(Maglev::IndexGeneration.obsolete.map(&:generation)).to eq(["active"])
  end

  it "fails the rebuild when knowledge changes during the scan" do
    record = RebuildRecord.records.first
    adapter = Class.new(RebuildEmbedding) do
      define_method(:embed) do |text|
        record.instance_variable_set(:@name, "changed during rebuild") if text == "second"
        super(text)
      end
    end.new

    expect do
      described_class.new(
        resources: [RebuildRecord],
        vector_store: Maglev::VectorStores::Memory.new,
        embedding_adapter: adapter,
        embedding_dimensions: 2,
        generation: "changed"
      ).rebuild!
    end.to raise_error(Maglev::IndexRebuilder::SourceChanged)

    expect(Maglev::IndexGeneration.find_by!(generation: "changed").status).to eq("failed")
  end

  it "rejects cutover after an identity-affecting configuration change" do
    generation = described_class.new(
      resources: [RebuildRecord],
      vector_store: Maglev::VectorStores::Memory.new,
      embedding_adapter: RebuildEmbedding.new,
      embedding_dimensions: 2,
      generation: "incompatible"
    ).rebuild!
    original_chunk_size = Maglev.configuration.chunk_size
    Maglev.configuration.chunk_size = original_chunk_size + 1

    expect do
      Maglev.activate_index_generation!(
        generation.generation,
        embedding_adapter: RebuildEmbedding.new,
        embedding_dimensions: 2
      )
    end.to raise_error(Maglev::IndexGeneration::InvalidCutover, /manifest/)
    expect(Maglev.active_index_generation).to be_nil
  ensure
    Maglev.configuration.chunk_size = original_chunk_size
  end

  it "rejects cutover when a knowledge resource was registered after the rebuild" do
    generation = described_class.new(
      resources: [RebuildRecord],
      vector_store: Maglev::VectorStores::Memory.new,
      embedding_adapter: RebuildEmbedding.new,
      embedding_dimensions: 2,
      generation: "missing-resource"
    ).rebuild!
    allow(Maglev::Registry).to receive(:entries).and_return(
      [
        RebuildRegistryEntry.new(identifier: "rebuild_records", model_class: RebuildRecord, knowledge: true),
        RebuildRegistryEntry.new(identifier: "later_resource", model_class: RebuildRecord, knowledge: true)
      ]
    )

    expect do
      Maglev.activate_index_generation!(
        generation.generation,
        embedding_adapter: RebuildEmbedding.new,
        embedding_dimensions: 2
      )
    end.to raise_error(Maglev::IndexGeneration::InvalidCutover, /every registered knowledge resource/)
  end

  it "rejects cutover when a related knowledge source uses another database" do
    generation = described_class.new(
      resources: [RebuildRecord],
      vector_store: Maglev::VectorStores::Memory.new,
      embedding_adapter: RebuildEmbedding.new,
      embedding_dimensions: 2,
      generation: "cross-database"
    ).rebuild!
    related_model = Class.new do
      def self.table_name = "related_records"
      def self.connection_pool = Object.new
    end
    relation = Maglev::KnowledgeConfig::Relation.new(name: :related, depth: 1, limit: 1)
    config = instance_double(
      Maglev::KnowledgeConfig,
      relations: [relation],
      attached_sources: [],
      rich_text_sources: []
    )
    reflection = double(
      "related reflection",
      polymorphic?: false,
      klass: related_model,
      join_table: nil,
      through_reflection: nil
    )
    allow(RebuildRecord).to receive(:maglev_config).and_return(config)
    allow(RebuildRecord).to receive(:reflect_on_association).with("related").and_return(reflection)

    expect do
      Maglev.activate_index_generation!(
        generation.generation,
        embedding_adapter: RebuildEmbedding.new,
        embedding_dimensions: 2
      )
    end.to raise_error(Maglev::IndexGeneration::InvalidCutover, /every knowledge source/)
  end
end
