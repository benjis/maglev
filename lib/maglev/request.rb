# frozen_string_literal: true

module Maglev
  class Request
    MODES = %i[auto structured rag hybrid].freeze

    attr_reader :question, :mode, :resources, :base_relation, :user, :options

    def initialize(question:, mode: :auto, resources: [], base_relation: nil, user: nil, **options)
      normalized_mode = mode.to_sym
      raise ArgumentError, "invalid request mode" unless MODES.include?(normalized_mode)

      @question = question.to_s.freeze
      @mode = normalized_mode
      @resources = Array(resources).map { |resource| resource.to_s.freeze }.uniq.freeze
      @base_relation = base_relation
      @user = user
      @options = options.freeze
      freeze
    end
  end
end
