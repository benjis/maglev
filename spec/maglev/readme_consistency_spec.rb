# frozen_string_literal: true

require "spec_helper"

RSpec.describe "README consistency" do
  %w[README.md README.zh-CN.md].each do |readme_name|
    it "keeps the #{readme_name} Quick Start embedding dimensions consistent" do
      readme = File.read(File.expand_path("../../#{readme_name}", __dir__))
      quick_start = readme.match(/### 1\..*?### 3\./m).to_s

      generator_dimensions = quick_start.match(/maglev:install --embedding-dimensions=(\d+)/)&.captures&.first
      provider_dimensions = quick_start.match(/provider\.dimensions = (\d+)/)&.captures&.first

      expect(generator_dimensions).not_to be_nil
      expect(provider_dimensions).not_to be_nil
      expect(generator_dimensions).to eq(provider_dimensions)
    end

    it "documents the #{readme_name} index identity and atomic store upgrade contract" do
      readme = File.read(File.expand_path("../../#{readme_name}", __dir__))

      %w[index_version fetch(ids:) replace_owner maglev:upgrade_index_version maglev:reindex_all HNSW].each do |term|
        expect(readme).to include(term)
      end
      expect(readme).to match(/vector.*column|向量列/i)
      expect(readme).to match(/embedding_adapter_id/)
      expect(readme).to match(/delete_by_owner.*upsert|delete.*upsert/im)
      expect(readme).to include("maglev-index")
      expect(readme).to match(/format version.*1|格式版本.*1/i)
      expect(readme).to match(/nullable.*index_version|可空.*index_version/i)
      expect(readme).to match(/legacy.*unavailable.*full reindex|旧记录.*完整重建.*不会参与检索|完整重建.*旧记录.*不会参与检索/i)
      expect(readme).to match(/dimension.*before reindex|维度.*再执行全量重建/i)
      expect(readme).to match(/fail.*preserve.*previous.*generation|失败.*保留上一代/im)
      expect(readme).to match(/delete_by_owner.*upsert.*not atomic|delete_by_owner.*upsert.*并不原子/im)
    end
  end
end
