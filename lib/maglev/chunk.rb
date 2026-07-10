# frozen_string_literal: true

require "active_record"
require "neighbor"

module Maglev
  class Chunk < ActiveRecord::Base
    self.table_name = "maglev_chunks"

    belongs_to :owner, polymorphic: true

    has_neighbors :embedding
  end
end
