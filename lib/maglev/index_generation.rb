# frozen_string_literal: true

require "active_record"

require_relative "index_identity"

module Maglev
  class IndexGeneration < ActiveRecord::Base
    class InvalidCutover < StandardError; end

    self.table_name = "maglev_index_generations"

    scope :obsolete, -> { where(status: "obsolete").order(:created_at) }
    scope :stale_builds, ->(before:) { where(status: "building").where(updated_at: ...before).order(:updated_at) }

    class << self
      def active
        find_by(status: "active")
      end

      def start!(generation:, representation_version:, manifest:, expected_record_count:)
        create!(
          generation: generation,
          status: "building",
          representation_version: representation_version,
          manifest: manifest,
          expected_record_count: expected_record_count,
          indexed_record_count: 0,
          started_at: Time.now.utc
        )
      end
    end

    def record_indexed!
      with_lock { update!(indexed_record_count: indexed_record_count + 1) }
      self
    end

    def heartbeat!
      self.class.where(id: id, status: "building").touch_all
      self
    end

    def complete!
      with_lock do
        unless status == "building" && indexed_record_count == expected_record_count
          raise InvalidCutover, "index generation is incomplete"
        end

        update!(status: "completed", completed_at: Time.now.utc)
      end
      self
    end

    def fail!(error)
      with_lock do
        update!(
          status: "failed",
          failure_class: error.class.name,
          failed_at: Time.now.utc
        )
      end
      self
    end

    def abort!
      with_lock do
        unless status == "building"
          raise InvalidCutover, "only a building index generation can be aborted"
        end

        update!(status: "failed", failure_class: "InterruptedRebuild", failed_at: Time.now.utc)
      end
      self
    end

    def cutover!(current_manifest:)
      self.class.transaction do
        lock!
        validate_cutover!(current_manifest)
        self.class.where(status: "active").where.not(id: id)
          .update_all(status: "obsolete", updated_at: Time.now.utc)
        update!(status: "active", activated_at: Time.now.utc)
      end
      self
    end

    private

    def validate_cutover!(current_manifest)
      unless status == "completed" && indexed_record_count == expected_record_count
        raise InvalidCutover, "only a complete index generation can be activated"
      end
      unless representation_version == IndexIdentity::REPRESENTATION_VERSION
        raise InvalidCutover, "index generation representation is incompatible"
      end
      unless manifest == current_manifest
        raise InvalidCutover, "index generation manifest is incompatible with current resources"
      end
    end
  end
end
