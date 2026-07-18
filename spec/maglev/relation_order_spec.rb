# frozen_string_literal: true

require "spec_helper"
require "maglev/knowledge_config"

class OrderTestRecord
  def self.attribute_names
    %w[id name industry description]
  end
end

RSpec.describe "Relation order DSL" do
  describe "include_related order parameter" do
    it "accepts a Symbol order" do
      config = Maglev::KnowledgeConfig.build(OrderTestRecord) do
        expose :name
        include_related :items, depth: 1, limit: 10, order: :created_at
      end

      relation = config.relations.first
      expect(relation.order).to eq({created_at: :asc})
    end

    it "accepts a String order" do
      config = Maglev::KnowledgeConfig.build(OrderTestRecord) do
        expose :name
        include_related :items, depth: 1, limit: 10, order: "created_at"
      end

      relation = config.relations.first
      expect(relation.order).to eq({created_at: :asc})
    end

    it "accepts a Hash order with asc/desc" do
      config = Maglev::KnowledgeConfig.build(OrderTestRecord) do
        expose :name
        include_related :items, depth: 1, limit: 10, order: {name: :desc, created_at: :asc}
      end

      relation = config.relations.first
      expect(relation.order).to eq({name: :desc, created_at: :asc})
    end

    it "defaults order to nil when not specified" do
      config = Maglev::KnowledgeConfig.build(OrderTestRecord) do
        expose :name
        include_related :items, depth: 1, limit: 10
      end

      relation = config.relations.first
      expect(relation.order).to be_nil
    end

    it "rejects empty order Hash" do
      expect do
        Maglev::KnowledgeConfig.build(OrderTestRecord) do
          expose :name
          include_related :items, depth: 1, limit: 10, order: {}
        end
      end.to raise_error(Maglev::ConfigurationError, /order/)
    end

    it "rejects Array order" do
      expect do
        Maglev::KnowledgeConfig.build(OrderTestRecord) do
          expose :name
          include_related :items, depth: 1, limit: 10, order: [:name]
        end
      end.to raise_error(Maglev::ConfigurationError, /order/)
    end

    it "rejects invalid direction in Hash order" do
      expect do
        Maglev::KnowledgeConfig.build(OrderTestRecord) do
          expose :name
          include_related :items, depth: 1, limit: 10, order: {name: :up}
        end
      end.to raise_error(Maglev::ConfigurationError, /order/)
    end

    it "rejects non-Symbol/String/Hash/Array order" do
      expect do
        Maglev::KnowledgeConfig.build(OrderTestRecord) do
          expose :name
          include_related :items, depth: 1, limit: 10, order: 42
        end
      end.to raise_error(Maglev::ConfigurationError, /order/)
    end
  end

  describe "Relation order attribute" do
    it "stores order immutably" do
      config = Maglev::KnowledgeConfig.build(OrderTestRecord) do
        expose :name
        include_related :items, depth: 1, limit: 10, order: :name
      end

      relation = config.relations.first
      expect(relation).to be_frozen
      expect { relation.order[:id] = :desc }.to raise_error(FrozenError)
    end
  end
end
