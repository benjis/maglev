# frozen_string_literal: true

class AddSourceIdentityToMaglevChunks < ActiveRecord::Migration[7.1]
  def up
    add_column :maglev_chunks, :source_identity, :string
    add_column :maglev_chunks, :source_type, :string
    add_column :maglev_chunks, :tenant_id, :string
    execute "UPDATE maglev_chunks SET source_identity = source, source_type = 'snapshot' WHERE source_identity IS NULL"
    change_column_null :maglev_chunks, :source_identity, false
    change_column_null :maglev_chunks, :source_type, false
    add_index :maglev_chunks, [:owner_model_name, :owner_id, :source_type, :index_version], name: "index_maglev_chunks_for_filtered_retrieval"
    add_index :maglev_chunks, :tenant_id
    create_table :maglev_index_states do |t|
      t.string :owner_type, null: false
      t.bigint :owner_id, null: false
      t.string :status, null: false
      t.string :active_index_version, limit: 64
      t.integer :chunk_count, null: false, default: 0
      t.datetime :last_success_at
      t.string :latest_failure_class
      t.datetime :latest_failure_at
      t.boolean :rebuild_required, null: false, default: false
      t.timestamps
    end
    add_index :maglev_index_states, [:owner_type, :owner_id], unique: true
  end

  def down
    drop_table :maglev_index_states
    remove_index :maglev_chunks, :tenant_id
    remove_index :maglev_chunks, name: "index_maglev_chunks_for_filtered_retrieval"
    remove_columns :maglev_chunks, :source_identity, :source_type, :tenant_id
  end
end
