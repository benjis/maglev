# frozen_string_literal: true

class CreateMaglevIndexGenerations < ActiveRecord::Migration[7.1]
  def up
    add_column :maglev_chunks, :generation, :string
    remove_index :maglev_chunks, name: "index_maglev_chunks_on_owner_source_chunk"
    add_index :maglev_chunks, [:generation, :owner_type, :owner_id, :source, :chunk_index],
      unique: true, name: "index_maglev_chunks_on_generation_owner_source_chunk"
    add_index :maglev_chunks, [:generation, :resource_identifier, :owner_id, :source_type, :index_version],
      name: "index_maglev_chunks_for_generation_retrieval"

    create_table :maglev_index_generations do |t|
      t.string :generation, null: false
      t.string :status, null: false
      t.string :representation_version, null: false
      t.jsonb :manifest, null: false, default: {}
      t.integer :expected_record_count, null: false
      t.integer :indexed_record_count, null: false, default: 0
      t.string :failure_class
      t.datetime :started_at, null: false
      t.datetime :completed_at
      t.datetime :activated_at
      t.datetime :failed_at
      t.timestamps
    end

    add_index :maglev_index_generations, :generation, unique: true
    add_index :maglev_index_generations, :status,
      unique: true, where: "status = 'active'",
      name: "index_maglev_index_generations_on_single_active"
  end

  def down
    drop_table :maglev_index_generations
    remove_index :maglev_chunks, name: "index_maglev_chunks_for_generation_retrieval"
    remove_index :maglev_chunks, name: "index_maglev_chunks_on_generation_owner_source_chunk"
    add_index :maglev_chunks, [:owner_type, :owner_id, :source, :chunk_index],
      unique: true, name: "index_maglev_chunks_on_owner_source_chunk"
    remove_column :maglev_chunks, :generation
  end
end
