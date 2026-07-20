# frozen_string_literal: true

require_relative "index_state"

module Maglev
  class IndexDiagnostics
    State = Data.define(:owner_type, :owner_id, :status, :active_index_version, :chunk_count,
      :last_success_at, :latest_failure, :rebuild_required)

    class << self
      def record_started(owner_type:, owner_id:, index_version:)
        return unless available?

        previous = IndexState.find_by(owner_type: owner_type.to_s, owner_id: owner_id)
        persist(owner_type, owner_id, status: previous&.last_success_at ? "rebuilding" : "indexing",
          active_index_version: index_version, rebuild_required: true)
      end

      def record_success(owner_type:, owner_id:, index_version:, chunk_count:)
        return unless available?

        persist(owner_type, owner_id, status: "ready", active_index_version: index_version,
          chunk_count: chunk_count, last_success_at: Time.now.utc, latest_failure_class: nil,
          latest_failure_at: nil, rebuild_required: false)
      end

      def record_failure(owner_type:, owner_id:, index_version:, error:)
        return unless available?

        persist(owner_type, owner_id, status: "failed", active_index_version: index_version,
          latest_failure_class: error.class.name, latest_failure_at: Time.now.utc, rebuild_required: true)
      end

      def record_unindexed(owner_type:, owner_id:)
        return unless available?

        persist(owner_type, owner_id, status: "not_indexed", active_index_version: nil,
          chunk_count: 0, rebuild_required: false)
      end

      def status(owner_type:, owner_id:)
        return empty_state(owner_type, owner_id) unless available?

        row = IndexState.find_by(owner_type: owner_type.to_s, owner_id: owner_id)
        return empty_state(owner_type, owner_id) unless row

        State.new(owner_type: row.owner_type, owner_id: row.owner_id, status: row.status.to_sym,
          active_index_version: row.active_index_version, chunk_count: row.chunk_count,
          last_success_at: row.last_success_at, latest_failure: failure_for(row),
          rebuild_required: row.rebuild_required)
      end

      private

      def available?
        IndexState.table_exists?
      rescue ActiveRecord::ConnectionNotDefined, ActiveRecord::StatementInvalid
        false
      end

      def persist(owner_type, owner_id, **attributes)
        row = IndexState.create_or_find_by!(owner_type: owner_type.to_s, owner_id: owner_id) do |state|
          state.assign_attributes(attributes)
        end
        row.with_lock do
          row.update!(attributes)
        end
      end

      def empty_state(owner_type, owner_id)
        State.new(owner_type: owner_type.to_s, owner_id: owner_id, status: :not_indexed,
          active_index_version: nil, chunk_count: 0, last_success_at: nil,
          latest_failure: nil, rebuild_required: false)
      end

      def failure_for(row)
        return unless row.latest_failure_class

        {error_class: row.latest_failure_class, occurred_at: row.latest_failure_at}.freeze
      end
    end
  end
end
