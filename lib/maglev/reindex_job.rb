# frozen_string_literal: true

require "active_job"

require_relative "indexer"

module Maglev
  class ReindexJob < ActiveJob::Base
    queue_as :default

    def perform(owner_class_name, owner_id)
      owner_class = owner_class_name.constantize
      owner = owner_class.find(owner_id)

      begin
        provider_call = ProviderCall.new(max_attempts: 1)
        Indexer.new(owner, provider_call: provider_call).index
      rescue RetryableProviderError => error
        if executions < Maglev.configuration.provider_max_attempts
          instrument_reindex("maglev.reindex.retry", owner_class_name, owner_id, error)
          retry_job(wait: 0)
        else
          instrument_reindex("maglev.reindex.exhausted", owner_class_name, owner_id, error)
          raise
        end
      rescue PermanentProviderError => error
        instrument_reindex("maglev.reindex.discard", owner_class_name, owner_id, error)
      end
    rescue ActiveRecord::RecordNotFound => error
      instrument_reindex("maglev.reindex.discard", owner_class_name, owner_id, error)
    end

    private

    def instrument_reindex(name, owner_class_name, owner_id, error)
      ActiveSupport::Notifications.instrument(
        name,
        job_class: self.class.name,
        owner_class: owner_class_name,
        owner_id: owner_id,
        error_class: error.class.name,
        execution_count: executions,
        attempt: executions,
        max_attempts: Maglev.configuration.provider_max_attempts
      )
    end
  end
end
