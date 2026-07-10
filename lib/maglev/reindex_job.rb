# frozen_string_literal: true

require "active_job"

require_relative "indexer"

module Maglev
  class ReindexJob < ActiveJob::Base
    queue_as :default

    def perform(owner_class_name, owner_id)
      owner = owner_class_name.constantize.find(owner_id)
      Indexer.new(owner).index
    end
  end
end
