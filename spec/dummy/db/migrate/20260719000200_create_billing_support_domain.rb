# frozen_string_literal: true

class CreateBillingSupportDomain < ActiveRecord::Migration[7.1]
  def change
    create_table :accounts do |t|
      t.string :name, null: false
      t.string :tenant_key, null: false
      t.timestamps
      t.index :tenant_key, unique: true
    end

    create_table :invoices do |t|
      t.references :account, null: false, foreign_key: true
      t.string :number, null: false
      t.string :status, null: false
      t.decimal :amount, precision: 12, scale: 2, null: false
      t.date :due_on, null: false
      t.datetime :paid_at
      t.text :internal_note
      t.timestamps
      t.index [:account_id, :number], unique: true
    end

    create_table :support_tickets do |t|
      t.references :account, null: false, foreign_key: true
      t.string :subject, null: false
      t.text :body, null: false
      t.string :status, null: false
      t.string :priority, null: false
      t.text :private_note
      t.timestamps
    end
  end
end
