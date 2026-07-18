# frozen_string_literal: true

module Maglev
  class Router
    ROUTES = %i[structured rag hybrid unsupported clarification_required].freeze
    MAX_RESOURCES = 12
    MAX_ITEMS = 40
    MAX_DESCRIPTION_CHARACTERS = 500

    Decision = Struct.new(:route, :confidence, :reasons, :resources) do
      def initialize(**attributes)
        attributes[:route] = attributes.fetch(:route).to_sym
        attributes[:confidence] = Float(attributes.fetch(:confidence))
        attributes[:reasons] = Array(attributes.fetch(:reasons)).map { |reason| reason.to_s.freeze }.freeze
        attributes[:resources] = Array(attributes.fetch(:resources)).map { |resource| resource.to_s.freeze }.freeze
        super
        freeze
      end
    end

    def initialize(classifier:)
      @classifier = classifier
    end

    def route(request)
      raise ArgumentError, "a Maglev::Request is required" unless request.is_a?(Request)

      return decision(route: request.mode, confidence: 1.0, reasons: ["explicit_mode"], request: request) unless request.mode == :auto

      unless @classifier&.respond_to?(:classify)
        raise ConfigurationError, "routing adapter is not configured"
      end

      output = @classifier.classify(question: request.question, capabilities: capability_summaries(request))
      raise PermanentProviderError, "Routing provider returned invalid output" unless output.is_a?(Hash)

      route = output["route"]&.to_sym
      confidence = output["confidence"]
      reasons = output["reasons"]
      unless ROUTES.include?(route) && confidence.is_a?(Numeric) && (0.0..1.0).cover?(confidence) &&
          reasons.is_a?(Array) && reasons.all? { |reason| reason.is_a?(String) }
        raise PermanentProviderError, "Routing provider returned invalid output"
      end

      decision(route: route, confidence: confidence, reasons: reasons, request: request)
    end

    private

    def decision(route:, confidence:, reasons:, request:)
      Decision.new(route: route, confidence: confidence, reasons: reasons, resources: request.resources)
    end

    def capability_summaries(request)
      request.resources.first(MAX_RESOURCES).filter_map do |identifier|
        entry = Registry.fetch(identifier)
        next unless entry

        queryable = entry.queryable
        knowledge = entry.knowledge
        sources = if knowledge
          knowledge.exposed_attributes + knowledge.attached_sources.map(&:name) + knowledge.rich_text_sources.map(&:name)
        else
          []
        end
        {
          identifier: entry.identifier,
          description: entry.description.to_s.each_char.first(MAX_DESCRIPTION_CHARACTERS).join,
          structured: !queryable.nil?,
          rag: !knowledge.nil?,
          fields: Array(queryable&.fields).map(&:name).first(MAX_ITEMS).freeze,
          sources: sources.uniq.first(MAX_ITEMS).freeze
        }.freeze
      end.freeze
    end
  end
end
