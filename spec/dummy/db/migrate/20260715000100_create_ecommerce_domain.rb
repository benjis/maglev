# frozen_string_literal: true

class CreateEcommerceDomain < ActiveRecord::Migration[7.1]
  def change
    enable_extension "vector"

    create_table :customers do |t|
      t.string :name, null: false
      t.string :email, null: false
      t.timestamps
      t.index :email, unique: true
    end

    create_table :customer_profiles do |t|
      t.references :customer, null: false, foreign_key: true, index: {unique: true}
      t.text :bio
      t.string :location
      t.timestamps
    end

    create_table :categories do |t|
      t.string :name, null: false
      t.text :description
      t.timestamps
    end

    create_table :products do |t|
      t.string :name, null: false
      t.string :sku, null: false
      t.decimal :price, precision: 12, scale: 2, null: false
      t.string :status, null: false
      t.timestamps
      t.index :sku, unique: true
    end

    create_table :product_variants do |t|
      t.references :product, null: false, foreign_key: true
      t.string :name, null: false
      t.string :sku, null: false
      t.decimal :price, precision: 12, scale: 2, null: false
      t.timestamps
      t.index :sku, unique: true
    end

    create_table :inventories do |t|
      t.references :product_variant, null: false, foreign_key: true, index: {unique: true}
      t.integer :quantity, null: false
      t.string :warehouse, null: false
      t.timestamps
    end

    create_table :product_categories do |t|
      t.references :product, null: false, foreign_key: true
      t.references :category, null: false, foreign_key: true
      t.timestamps
      t.index %i[product_id category_id], unique: true
    end

    create_table :tags do |t|
      t.string :name, null: false
      t.timestamps
      t.index :name, unique: true
    end

    create_table :taggings do |t|
      t.references :tag, null: false, foreign_key: true
      t.references :taggable, polymorphic: true, null: false
      t.timestamps
      t.index %i[tag_id taggable_type taggable_id], unique: true
    end

    create_table :orders do |t|
      t.references :customer, null: false, foreign_key: true
      t.string :status, null: false
      t.decimal :total, precision: 12, scale: 2, null: false
      t.datetime :placed_at, null: false
      t.timestamps
    end

    create_table :order_items do |t|
      t.references :order, null: false, foreign_key: true
      t.references :product, null: false, foreign_key: true
      t.references :product_variant, null: true, foreign_key: true
      t.integer :quantity, null: false
      t.decimal :unit_price, precision: 12, scale: 2, null: false
      t.timestamps
    end

    create_table :reviews do |t|
      t.references :customer, null: false, foreign_key: true
      t.references :product, null: false, foreign_key: true
      t.integer :rating, null: false
      t.string :title, null: false
      t.text :body, null: false
      t.timestamps
    end

    create_table :comments do |t|
      t.references :customer, null: false, foreign_key: true
      t.references :commentable, polymorphic: true, null: false
      t.text :body, null: false
      t.timestamps
    end

    create_table :customer_tags do |t|
      t.references :customer, null: false, foreign_key: true
      t.references :tag, null: false, foreign_key: true
      t.timestamps
      t.index %i[customer_id tag_id], unique: true
    end

    create_table :active_storage_blobs do |t|
      t.string :key, null: false
      t.string :filename, null: false
      t.string :content_type
      t.text :metadata
      t.string :service_name, null: false
      t.bigint :byte_size, null: false
      t.string :checksum
      t.datetime :created_at, precision: 6, null: false
      t.index :key, unique: true
    end

    create_table :active_storage_attachments do |t|
      t.string :name, null: false
      t.references :record, null: false, polymorphic: true, index: false
      t.references :blob, null: false, foreign_key: {to_table: :active_storage_blobs}
      t.datetime :created_at, precision: 6, null: false
      t.index %i[record_type record_id name blob_id], unique: true, name: :index_active_storage_attachments_uniqueness
    end

    create_table :active_storage_variant_records do |t|
      t.references :blob, null: false, foreign_key: {to_table: :active_storage_blobs}, index: false
      t.string :variation_digest, null: false
      t.index %i[blob_id variation_digest], unique: true, name: :index_active_storage_variant_records_uniqueness
    end

    create_table :action_text_rich_texts do |t|
      t.string :name, null: false
      t.text :body
      t.references :record, null: false, polymorphic: true, index: false
      t.timestamps
      t.index %i[record_type record_id name], unique: true, name: :index_action_text_rich_texts_uniqueness
    end

    create_table :maglev_chunks do |t|
      t.string :owner_type, null: false
      t.bigint :owner_id, null: false
      t.string :owner_model_name, null: false
      t.string :source, null: false
      t.integer :chunk_index, null: false
      t.text :content, null: false
      t.string :content_checksum, null: false
      t.string :embedding_model, null: false
      t.vector :embedding, limit: 3, null: false
      t.timestamps
      t.index %i[owner_type owner_id source chunk_index], unique: true, name: :index_maglev_chunks_on_owner_source_chunk
      t.index :owner_model_name
      t.index :embedding, using: :hnsw, opclass: :vector_cosine_ops
    end
  end
end
