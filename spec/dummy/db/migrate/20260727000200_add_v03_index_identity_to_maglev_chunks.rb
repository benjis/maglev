# frozen_string_literal: true

class AddV03IndexIdentityToMaglevChunks < ActiveRecord::Migration[7.1]
  def change
    add_column :maglev_chunks, :resource_identifier, :string
    add_column :maglev_chunks, :representation_version, :string
    add_column :maglev_chunks, :knowledge_policy_digest, :string, limit: 64
    add_index :maglev_chunks,
      [:resource_identifier, :owner_id, :source_type, :index_version],
      name: "index_maglev_chunks_for_v03_filtered_retrieval"
  end
end
