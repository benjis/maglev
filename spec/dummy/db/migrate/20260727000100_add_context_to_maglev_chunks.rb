# frozen_string_literal: true

class AddContextToMaglevChunks < ActiveRecord::Migration[7.1]
  def change
    add_column :maglev_chunks, :context, :jsonb, null: false, default: {}
  end
end
