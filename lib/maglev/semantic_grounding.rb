# frozen_string_literal: true

require "json"

module Maglev
  class SemanticGrounding
    MAX_ITEMS = 100
    MAX_SERIALIZED_BYTES = 16_384

    attr_reader :snapshot_fingerprint, :contexts, :meanings, :claim_ids, :evidence_ids,
      :assumptions, :gaps, :contests

    def self.from(context, meaning_ids: nil, contest_ids: [])
      unless context.is_a?(AuthorizedSemanticContext)
        raise ArgumentError, "semantic grounding requires an Authorized Semantic Context"
      end

      available = context.meanings.to_h { |meaning| [meaning.fetch(:id), meaning] }
      selected_ids = meaning_ids.nil? ? available.keys : Array(meaning_ids).map(&:to_s)
      unless selected_ids.uniq == selected_ids && (selected_ids - available.keys).empty?
        raise ArgumentError, "semantic grounding contains an unauthorized meaning"
      end
      contest_ids = Array(contest_ids).map(&:to_s)
      unless contest_ids.uniq == contest_ids && (contest_ids - selected_ids).empty?
        raise ArgumentError, "semantic grounding contains an unauthorized contest"
      end

      selected = selected_ids.map { |identifier| available.fetch(identifier) }
      assertion_ids = selected_ids + context.edges.filter_map do |edge|
        edge.id if selected_ids.include?(edge.source_id) && selected_ids.include?(edge.target_id)
      end
      claims = context.claims.select { |claim| assertion_ids.include?(claim.assertion_id) }
      evidence_ids = claims.map(&:evidence_id).uniq

      new(
        snapshot_fingerprint: context.snapshot_fingerprint,
        contexts: selected.map { |meaning| meaning.fetch(:context) }.uniq.sort,
        meanings: selected.map do |meaning|
          {
            id: meaning.fetch(:id),
            semantic_status: meaning.fetch(:semantic_status),
            execution_status: meaning.fetch(:execution_status)
          }
        end,
        claim_ids: claims.map(&:id),
        evidence_ids: evidence_ids,
        assumptions: selected.filter_map do |meaning|
          meaning.fetch(:id) if meaning.fetch(:semantic_status) == :reconstructed
        end,
        gaps: selected.filter_map do |meaning|
          meaning.fetch(:id) if meaning.fetch(:semantic_status) == :missing
        end,
        contests: (contest_ids + selected.filter_map do |meaning|
          meaning.fetch(:id) if meaning.fetch(:semantic_status) == :contested
        end).uniq
      )
    end

    def self.minimal(context)
      return unless context
      unless context.is_a?(AuthorizedSemanticContext)
        raise ArgumentError, "semantic grounding requires an Authorized Semantic Context"
      end

      new(snapshot_fingerprint: context.snapshot_fingerprint)
    end

    def initialize(snapshot_fingerprint:, contexts: [], meanings: [], claim_ids: [], evidence_ids: [],
      assumptions: [], gaps: [], contests: [])
      @snapshot_fingerprint = snapshot_fingerprint.to_s.freeze
      @contexts = immutable_strings(:contexts, contexts)
      @meanings = immutable_meanings(meanings)
      @claim_ids = immutable_strings(:claim_ids, claim_ids)
      @evidence_ids = immutable_strings(:evidence_ids, evidence_ids)
      @assumptions = immutable_strings(:assumptions, assumptions)
      @gaps = immutable_strings(:gaps, gaps)
      @contests = immutable_strings(:contests, contests)
      @presentation = {
        snapshot_fingerprint: @snapshot_fingerprint,
        contexts: @contexts,
        meanings: @meanings,
        claim_ids: @claim_ids,
        evidence_ids: @evidence_ids,
        assumptions: @assumptions,
        gaps: @gaps,
        contests: @contests
      }.freeze
      if JSON.generate(@presentation).bytesize > MAX_SERIALIZED_BYTES
        raise ArgumentError, "semantic grounding exceeds serialized size limit"
      end

      freeze
    end

    def to_h
      @presentation
    end

    def minimal?
      [contexts, meanings, claim_ids, evidence_ids, assumptions, gaps, contests].all?(&:empty?)
    end

    private

    def immutable_strings(name, values)
      values = Array(values)
      raise ArgumentError, "#{name} exceeds item limit" if values.length > MAX_ITEMS

      values.map { |value| value.to_s.freeze }.freeze
    end

    def immutable_meanings(values)
      values = Array(values)
      raise ArgumentError, "meanings exceeds item limit" if values.length > MAX_ITEMS

      values.map do |meaning|
        {
          id: meaning.fetch(:id).to_s.freeze,
          semantic_status: meaning.fetch(:semantic_status).to_sym,
          execution_status: meaning.fetch(:execution_status).to_sym
        }.freeze
      end.freeze
    end

    private_class_method :new
  end
end
