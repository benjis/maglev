# frozen_string_literal: true

require "spec_helper"
require "maglev/dependency_graph"

class DependencyGraphLeaf
  attr_accessor :id, :parents

  def initialize(id, parents: [])
    @id = id
    @parents = parents
  end
end

class DependencyGraphBranch < DependencyGraphLeaf
end

class DependencyGraphRoot < DependencyGraphLeaf
end

RSpec.describe Maglev::DependencyGraph do
  before do
    @original_edges = described_class.instance_variable_get(:@edges)
    described_class.instance_variable_set(:@edges, Hash.new { |hash, klass| hash[klass] = [] })
    @jobs = []
    allow(Maglev::ReindexJob).to receive(:perform_later) { |model, id| @jobs << [model, id] }
  end

  after do
    described_class.instance_variable_set(:@edges, @original_edges)
  end

  it "stores the compiled relation depth on registered edges" do
    relation = Struct.new(:related_class, :name, :inverse, :depth).new(
      DependencyGraphLeaf,
      :leaves,
      :parents,
      2
    )
    schema = Struct.new(:model_class, :relations).new(DependencyGraphBranch, [relation])
    allow(described_class).to receive(:install_callbacks)

    described_class.register(schema)

    edge = described_class.instance_variable_get(:@edges)[DependencyGraphLeaf].first
    expect(edge.depth).to eq(2)
  end

  it "updates the depth when the same logical edge is registered again" do
    relation = Struct.new(:related_class, :name, :inverse, :depth).new(
      DependencyGraphLeaf,
      :leaves,
      :parents,
      1
    )
    schema = Struct.new(:model_class, :relations).new(DependencyGraphBranch, [relation])
    allow(described_class).to receive(:install_callbacks)

    described_class.register(schema)
    relation.depth = 2
    described_class.register(schema)

    edges = described_class.instance_variable_get(:@edges)[DependencyGraphLeaf]
    expect(edges.map(&:depth)).to eq([2])
    expect(described_class).to have_received(:install_callbacks).once
  end

  it "terminates cycles and enqueues every affected owner once" do
    first = DependencyGraphBranch.new(1)
    second = DependencyGraphBranch.new(2)
    first.parents = [second]
    second.parents = [first]
    add_edge(DependencyGraphBranch)

    described_class.reindex_record_and_dependents_for(first)

    expect(@jobs).to contain_exactly(
      ["DependencyGraphBranch", 1],
      ["DependencyGraphBranch", 2]
    )
  end

  it "de-duplicates a shared ancestor in a diamond graph" do
    root = DependencyGraphRoot.new(1)
    left = DependencyGraphBranch.new(2, parents: [root])
    right = DependencyGraphBranch.new(3, parents: [root])
    leaf = DependencyGraphLeaf.new(4, parents: [left, right])
    add_edge(DependencyGraphLeaf)
    add_edge(DependencyGraphBranch)

    described_class.reindex_record_and_dependents_for(leaf)

    expect(@jobs.count(["DependencyGraphRoot", root.id])).to eq(1)
    expect(@jobs.size).to eq(4)
  end

  it "reindexes transitive ancestors of both previous and current owners" do
    old_root = DependencyGraphRoot.new(1)
    new_root = DependencyGraphRoot.new(2)
    old_parent = DependencyGraphBranch.new(3, parents: [old_root])
    new_parent = DependencyGraphBranch.new(4, parents: [new_root])
    leaf = DependencyGraphLeaf.new(5, parents: [new_parent])
    leaf.instance_variable_set(:@maglev_previous_dependent_owners, [old_parent])
    add_edge(DependencyGraphLeaf)
    add_edge(DependencyGraphBranch)

    described_class.reindex_dependents_for(leaf)

    expect(@jobs).to contain_exactly(
      ["DependencyGraphBranch", old_parent.id],
      ["DependencyGraphRoot", old_root.id],
      ["DependencyGraphBranch", new_parent.id],
      ["DependencyGraphRoot", new_root.id]
    )
  end

  it "stops before an ancestor whose edge depth is shorter than the source distance" do
    root = DependencyGraphRoot.new(1)
    branch = DependencyGraphBranch.new(2, parents: [root])
    leaf = DependencyGraphLeaf.new(3, parents: [branch])
    add_edge(DependencyGraphLeaf, depth: 1)
    add_edge(DependencyGraphBranch, depth: 1)

    described_class.reindex_record_and_dependents_for(leaf)

    expect(@jobs).to contain_exactly(
      ["DependencyGraphLeaf", leaf.id],
      ["DependencyGraphBranch", branch.id]
    )
  end

  it "reindexes an ancestor whose edge depth reaches the source distance" do
    root = DependencyGraphRoot.new(1)
    branch = DependencyGraphBranch.new(2, parents: [root])
    leaf = DependencyGraphLeaf.new(3, parents: [branch])
    add_edge(DependencyGraphLeaf, depth: 1)
    add_edge(DependencyGraphBranch, depth: 2)

    described_class.reindex_record_and_dependents_for(leaf)

    expect(@jobs).to contain_exactly(
      ["DependencyGraphLeaf", leaf.id],
      ["DependencyGraphBranch", branch.id],
      ["DependencyGraphRoot", root.id]
    )
  end

  def add_edge(related_class, depth: 3)
    edges = described_class.instance_variable_get(:@edges)
    edges[related_class] << described_class::Edge.new(nil, related_class, nil, :parents, depth)
  end
end
