# frozen_string_literal: true

class Tagging < ApplicationRecord
  belongs_to :tag, inverse_of: :taggings
  belongs_to :taggable, polymorphic: true, inverse_of: :taggings
end
