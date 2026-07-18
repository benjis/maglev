# frozen_string_literal: true

require "active_record"

module Maglev
  class IndexState < ActiveRecord::Base
    self.table_name = "maglev_index_states"
  end
end
