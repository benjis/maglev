# frozen_string_literal: true

require "spec_helper"

readmes = %w[README.md README.zh-CN.md README.ja.md].freeze
public_api_terms = %w[
  maglev_resource queryable knowledge Maglev.plan Maglev.execute
  maglev_request SupportTicket.search SupportTicket.retrieve SupportTicket.ask
  structured_first rag_first policy_limits evidence_requirements
].freeze
operations_terms = %w[
  index_version fetch(ids:) replace_owner maglev:upgrade_index_version
  maglev:upgrade_source_identity maglev:reindex_all HNSW embedding_adapter_id
  maglev-index delete_by_owner upsert
].freeze
beginner_dsl_terms = %w[
  description synonyms sensitive enum_values allow_unscoped_model_queries
  expose hide tags include_related expose_attached expose_rich_text
].freeze

RSpec.describe "README consistency" do
  readmes.each do |readme_name|
    it "keeps #{readme_name} synchronized with the v0.2 public architecture" do
      readme = File.read(File.expand_path("../../#{readme_name}", __dir__))

      (public_api_terms + operations_terms).each do |term|
        expect(readme).to include(term)
      end
      expect(readme).to include(":structured", ":rag", ":hybrid", ":auto")
      expect(readme).to include("authorization :required")
      expect(readme).to include("retrieval_max_candidates = 1000")
      expect(readme).not_to include("plan.to_sql")
      expect(readme).not_to include("has_knowledge")
    end

    it "keeps #{readme_name} installation and provider dimensions consistent" do
      readme = File.read(File.expand_path("../../#{readme_name}", __dir__))
      generator_dimensions = readme.match(/maglev:install --embedding-dimensions=(\d+)/)&.captures&.first
      provider_dimensions = readme.match(/provider\.dimensions = (\d+)/)&.captures&.first

      expect(generator_dimensions).to eq("1536")
      expect(provider_dimensions).to eq(generator_dimensions)
    end

    it "keeps #{readme_name} approachable with annotated examples and a DSL reference" do
      readme = File.read(File.expand_path("../../#{readme_name}", __dir__))
      invoice_example = readme.match(/class Invoice < ApplicationRecord.*?^end\n```/m).to_s

      expect(readme).to include("DSL", "SupportTicket.retrieve", "SupportTicket.ask")
      beginner_dsl_terms.each { |term| expect(readme).to include(term) }
      expect(invoice_example.scan(/^\s+# /).length).to be >= 10
      expect(readme).to include("mode: :hybrid", "hybrid_plan: :structured_first")
    end
  end
end
