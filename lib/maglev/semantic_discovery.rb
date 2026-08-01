# frozen_string_literal: true

require "digest"
require "prism"

require_relative "semantic_graph"
require_relative "registry"

module Maglev
  # Explicit, local-only discovery of deterministic semantic evidence.
  class SemanticDiscovery
    RUBY_GLOB = "**/*.rb"
    IGNORED_DIRECTORIES = %w[.git log node_modules storage tmp vendor].freeze
    EXPLICIT_KINDS = SemanticGraph::Node::KINDS.to_h do |kind|
      method_name = (kind == :semantic_context) ? :semantic_context : :"semantic_#{kind}"
      [method_name, kind]
    end.freeze
    STATE_FIELDS = %i[state status stage].freeze

    def initialize(root:, registry_entries: nil, models: nil)
      @root = Pathname(root).expand_path
      raise ArgumentError, "repository root does not exist: #{@root}" unless @root.directory?

      @registry_entries = registry_entries
      @models = models
      @nodes = {}
      @edges = {}
      @evidence = {}
      @claims = {}
    end

    def call
      discover_registry_and_reflection
      discover_unregistered_models
      ruby_files.each { |path| discover_ruby(path) }

      SemanticGraph.new(
        nodes: @nodes.values.sort_by(&:id),
        edges: @edges.values.sort_by(&:id),
        evidence: @evidence.values.sort_by(&:id),
        claims: @claims.values.sort_by(&:id)
      )
    end

    private

    def registry_entries
      @registry_entries || Registry.entries
    end

    def models
      return @models if @models
      return [] unless defined?(ActiveRecord::Base)

      ActiveRecord::Base.descendants.select do |model|
        source_file = Object.const_source_location(model.name.to_s)&.first
        !model.abstract_class? &&
          source_file &&
          Pathname(source_file).expand_path.to_s.start_with?("#{@root}/")
      end
    end

    def discover_registry_and_reflection
      registry_entries.sort_by(&:identifier).each do |entry|
        model = entry.model_class
        context = canonical(model.name)
        entity = add_node(:entity, context, context, available: !entry.queryable.nil?)
        add_observation(entity, :registry, "resource:#{entry.identifier}", :registry, :registry)
        discover_columns(model, entity, context)
        discover_associations(model, entity, context)
        discover_capabilities(entry, entity, context)
      end
    end

    def discover_columns(model, entity, context)
      return unless model.respond_to?(:columns_hash)

      model.columns_hash.sort.each do |name, _column|
        dimension = add_node(:dimension, context, canonical(name), available: registered_model?(model))
        add_edge(:describes, dimension, entity)
        add_observation(dimension, :reflection, "ruby:#{model.name}.#{name}", :reflection, :reflection)
        if model.respond_to?(:table_name)
          add_observation(dimension, :schema, "column:#{model.table_name}.#{name}", :schema, :schema)
        end

        enum_values = model.respond_to?(:defined_enums) ? model.defined_enums.fetch(name.to_s, {}).keys : []
        enum_values.sort.each do |value|
          state = add_node(:state, context, canonical(value), available: false)
          add_edge(:state_of, state, entity)
          add_observation(state, :reflection, "ruby:#{model.name}.#{name}.#{value}", :reflection, :reflection)
        end
      end
    end

    def discover_associations(model, entity, context)
      return unless model.respond_to?(:reflect_on_all_associations)

      model.reflect_on_all_associations.sort_by { |reflection| reflection.name.to_s }.each do |reflection|
        target_name = reflection_target_name(reflection)
        next if target_name.empty?

        target_context = canonical(target_name)
        target = add_node(:entity, target_context, target_context, available: registered_model_name?(target_name))
        edge = add_edge(:association, entity, target)
        add_observation(
          edge,
          :reflection,
          "ruby:#{model.name}.#{reflection.name}",
          :reflection,
          :reflection
        )
      end
    end

    def discover_capabilities(entry, entity, context)
      queryable = entry.queryable
      return unless queryable

      queryable.scopes.sort_by(&:name).each do |scope|
        term = add_node(:term, context, canonical(scope.name), available: true)
        add_edge(:classifies, term, entity)
        add_observation(term, :registry, "scope:#{entry.identifier}.#{scope.name}", :registry, :registry)
      end
      queryable.aggregates.sort_by { |name, _| name.to_s }.each do |aggregate, fields|
        Array((fields == true) ? "records" : fields).sort.each do |field|
          metric = add_node(:metric, context, canonical("#{aggregate}_#{field}"), available: true)
          add_edge(:measures, metric, entity)
          add_observation(
            metric,
            :registry,
            "aggregate:#{entry.identifier}.#{aggregate}.#{field}",
            :registry,
            :registry
          )
        end
      end
    end

    def discover_unregistered_models
      models.sort_by { |model| model.name.to_s }.each do |model|
        next if registered_model?(model)

        context = canonical(model.name)
        entity = add_node(:entity, context, context, available: false)
        add_observation(entity, :reflection, "ruby:#{model.name}", :reflection, :reflection)
        discover_columns(model, entity, context)
        discover_associations(model, entity, context)
      end
    end

    def discover_ruby(path)
      result = Prism.parse_file(path.to_s)
      raise SemanticGraph::ValidationError, "#{relative(path)}: #{result.errors.first.message}" unless result.success?

      SourceVisitor.new(self, path, result.value).visit
    end

    def ruby_files
      @root.glob(RUBY_GLOB).reject do |path|
        path.each_filename.any? { |part| IGNORED_DIRECTORIES.include?(part) }
      end.sort_by { |path| relative(path) }
    end

    def record_source(kind:, name:, owner:, path:, line:, symbol:, context: nil, polarity: :supports)
      canonical_name = canonical(name)
      return if canonical_name.empty?

      semantic_context = canonical(context || owner || "global")
      available = false
      node = add_node(kind, semantic_context, canonical_name, available: available)
      source_kind = test_path?(path) ? :test : :ruby
      basis = test_path?(path) ? :test : :syntax
      evidence = add_evidence(
        source_kind,
        "ruby:#{symbol}",
        :prism,
        file: relative(path),
        line: line,
        digest: Digest::SHA256.file(path).hexdigest
      )
      add_claim(node, evidence, basis, polarity)
      node
    end

    def record_simple_metric_binding(metric:, model_name:, aggregate:, field:, scope:, path:, line:)
      entry = registry_entries.find { |candidate| candidate.model_class.name == model_name }
      return unless entry&.queryable

      permitted = entry.queryable.aggregates.fetch(aggregate.to_sym, nil)
      return unless permitted == true || Array(permitted).map(&:to_s).include?(field.to_s)
      return if scope && entry.queryable.scopes.none? { |candidate| candidate.name.to_s == scope.to_s }

      entity_context = canonical(model_name)
      entity = @nodes["entity:#{entity_context}:#{entity_context}"]
      return unless entity

      executable_metric = add_node(:metric, metric.context, metric.name, available: true)
      add_edge(:measures, executable_metric, entity)
      aggregate_evidence = add_evidence(
        :ruby, "aggregate:#{entry.identifier}.#{aggregate}.#{field}", :prism,
        file: relative(path), line: line, digest: Digest::SHA256.file(path).hexdigest
      )
      add_claim(executable_metric, aggregate_evidence, :syntax, :supports)
      return unless scope

      term = add_node(:term, metric.context, canonical(scope), available: true)
      add_edge(:classifies, term, entity)
      add_edge(:applies, executable_metric, term)
      scope_evidence = add_evidence(
        :ruby, "scope:#{entry.identifier}.#{scope}", :prism,
        file: relative(path), line: line, digest: Digest::SHA256.file(path).hexdigest
      )
      add_claim(term, scope_evidence, :syntax, :supports)
    end

    def add_node(kind, context, name, available:)
      node = SemanticGraph::Node.new(
        kind: kind,
        context: canonical(context),
        name: canonical(name),
        execution_status: available ? :available : :unavailable
      )
      existing = @nodes[node.id]
      if existing && existing.execution_status == :unavailable && node.execution_status == :available
        @nodes[node.id] = node
      else
        @nodes[node.id] ||= node
      end
    end

    def add_edge(kind, source, target)
      edge = SemanticGraph::Edge.new(kind: kind, source_id: source.id, target_id: target.id)
      @edges[edge.id] ||= edge
    end

    def add_observation(assertion, source_kind, identity, extractor, basis)
      evidence = add_evidence(source_kind, identity, extractor)
      add_claim(assertion, evidence, basis, :supports)
    end

    def add_evidence(source_kind, identity, extractor, file: nil, line: nil, digest: nil)
      evidence = SemanticGraph::Evidence.new(
        source_kind: source_kind,
        stable_identity: identity,
        extractor: extractor,
        file: file,
        line: line,
        digest: digest
      )
      @evidence[evidence.id] ||= evidence
    end

    def add_claim(assertion, evidence, basis, polarity)
      claim = SemanticGraph::Claim.new(
        assertion_id: assertion.id,
        evidence_id: evidence.id,
        basis: basis,
        polarity: polarity
      )
      @claims[claim.id] ||= claim
    end

    def registered_model?(model)
      registry_entries.any? { |entry| entry.model_class == model && entry.queryable }
    end

    def registered_model_name?(name)
      registry_entries.any? { |entry| entry.model_class.name == name && entry.queryable }
    end

    def reflection_target_name(reflection)
      return reflection.class_name.to_s if reflection.respond_to?(:class_name)

      reflection.klass.name.to_s
    rescue NameError
      ""
    end

    def relative(path)
      path.relative_path_from(@root).to_s
    end

    def test_path?(path)
      relative(path).match?(%r{\A(?:spec|test)/})
    end

    def canonical(value)
      value.to_s
        .gsub("::", "_")
        .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
        .gsub(/([a-z\d])([A-Z])/, '\1_\2')
        .tr("- ", "_")
        .gsub(/[^a-zA-Z0-9_]/, "_")
        .downcase.squeeze("_")
        .sub(/\A_/, "")
        .sub(/_\z/, "")
        .then { |result| result.match?(/\A[a-z]/) ? result : "n_#{result}" }
        .slice(0, SemanticGraph::MAX_COMPONENT_CHARACTERS)
    end

    class SourceVisitor
      CLASS_KIND_SUFFIXES = {
        "Query" => :metric,
        "Service" => :action,
        "Job" => :action
      }.freeze

      def initialize(discovery, path, root)
        @discovery = discovery
        @path = path
        @root = root
        @semantic_contexts = {}
        @metrics = {}
      end

      def visit(node = @root, owners = [])
        return unless node

        if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
          owner = constant_name(node.constant_path)
          owners += [owner] unless owner.empty?
          record_class_semantics(owners.join("::"), node) if node.is_a?(Prism::ClassNode)
        elsif node.is_a?(Prism::DefNode)
          record_definition(node, owners.join("::"))
        elsif node.is_a?(Prism::CallNode)
          record_call(node, owners.join("::"))
        end
        node.compact_child_nodes.each { |child| visit(child, owners) }
      end

      private

      def record_class_semantics(owner, node)
        if model_path?
          @discovery.send(
            :record_source,
            kind: :entity,
            name: owner,
            owner: owner,
            path: @path,
            line: node.location.start_line,
            symbol: owner
          )
        end
        suffix, kind = CLASS_KIND_SUFFIXES.find { |candidate, _| owner.end_with?(candidate) }
        return unless suffix

        name = owner.split("::").last.delete_suffix(suffix)
        @discovery.send(
          :record_source,
          kind: kind,
          name: name,
          owner: owner,
          path: @path,
          line: node.location.start_line,
          symbol: owner
        )
      end

      def record_definition(node, owner)
        name = node.name.to_s
        kind = if name.end_with?("?")
          :term
        elsif name.end_with?("!")
          :transition
        end
        return unless kind

        @discovery.send(
          :record_source,
          kind: kind,
          name: name.delete_suffix("?").delete_suffix("!"),
          owner: owner,
          path: @path,
          line: node.location.start_line,
          symbol: "#{owner}##{name}"
        )
      end

      def record_call(node, owner)
        explicit_kind = EXPLICIT_KINDS[node.name]
        if explicit_kind
          value = literal(node.arguments&.arguments&.first)
          if value
            if explicit_kind == :semantic_context
              @semantic_contexts[owner] = value
              record(explicit_kind, value, owner, node, "#{owner}.#{node.name}.#{value}", context: value)
            else
              semantic = record(explicit_kind, value, owner, node, "#{owner}.#{node.name}.#{value}",
                context: @semantic_contexts[owner])
              @metrics[owner] = semantic if explicit_kind == :metric
            end
          end
          return
        end

        case node.name
        when :scope
          value = literal(node.arguments&.arguments&.first)
          record(:term, value, owner, node, "#{owner}.scope.#{value}") if value
        when :validates, :validate
          value = literal(node.arguments&.arguments&.first) || "validation"
          record(:business_rule, value, owner, node, "#{owner}.validation.#{value}")
        when :enum
          enum_values(node).each do |value|
            record(:state, value, owner, node, "#{owner}.enum.#{value}")
          end
        else
          if %i[count count_distinct sum average minimum maximum].include?(node.name) && @metrics[owner]
            record_metric_binding(node, owner)
          elsif node.name.to_s.match?(/\A(?:before|after|around)_(?:validation|save|create|update|destroy|commit)\z/)
            value = literal(node.arguments&.arguments&.first) || node.name
            record(:business_rule, value, owner, node, "#{owner}.#{node.name}.#{value}")
          else
            record_state_write(node, owner)
          end
        end
      end

      def record_state_write(node, owner)
        field = node.name.to_s.delete_suffix("=").to_sym
        return unless node.name.to_s.end_with?("=") && STATE_FIELDS.include?(field)

        value = literal(node.arguments&.arguments&.first)
        return unless value

        record(:state, value, owner, node, "#{owner}##{field}=#{value}")
        record(:transition, "to_#{value}", owner, node, "#{owner}##{field}=#{value}.transition")
      end

      def record(kind, value, owner, node, symbol, context: nil)
        @discovery.send(
          :record_source,
          kind: kind,
          name: value,
          owner: owner,
          context: context,
          path: @path,
          line: node.location.start_line,
          symbol: symbol
        )
      end

      def record_metric_binding(node, owner)
        field = literal(node.arguments&.arguments&.first) || "records"
        receiver = node.receiver
        scope = receiver.name.to_s if receiver.is_a?(Prism::CallNode)
        model_receiver = receiver.is_a?(Prism::CallNode) ? receiver.receiver : receiver
        model_name = constant_name(model_receiver)
        return if model_name.empty?

        @discovery.send(
          :record_simple_metric_binding,
          metric: @metrics.fetch(owner),
          model_name: model_name,
          aggregate: node.name,
          field: field,
          scope: scope,
          path: @path,
          line: node.location.start_line
        )
      end

      def enum_values(node)
        argument = node.arguments&.arguments&.rfind do |candidate|
          candidate.is_a?(Prism::KeywordHashNode) || candidate.is_a?(Prism::HashNode)
        end
        return [] unless argument.is_a?(Prism::KeywordHashNode) || argument.is_a?(Prism::HashNode)

        argument.elements.flat_map do |element|
          next [] unless element.is_a?(Prism::AssocNode)

          value = element.value
          if value.is_a?(Prism::ArrayNode)
            value.elements.filter_map { |item| literal(item) }
          elsif value.is_a?(Prism::HashNode)
            value.elements.filter_map { |item| literal(item.key) if item.is_a?(Prism::AssocNode) }
          else
            [literal(element.key)].compact
          end
        end
      end

      def literal(node)
        case node
        when Prism::SymbolNode, Prism::StringNode then node.unescaped
        when Prism::IntegerNode then node.value.to_s
        end
      end

      def constant_name(node)
        node&.location&.slice.to_s.sub(/\A::/, "")
      end

      def model_path?
        @path.to_s.match?(%r{/app/models/})
      end
    end
  end
end
