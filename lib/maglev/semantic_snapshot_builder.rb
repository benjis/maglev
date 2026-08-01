# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "tempfile"

require_relative "semantic_discovery"
require_relative "semantic_snapshot"
require_relative "version"

module Maglev
  # Builds the local semantic snapshot as a validated, atomic derived artifact.
  class SemanticSnapshotBuilder
    DEFAULT_PATH = "config/maglev/semantic-layer.generated.yml"
    IGNORED_DIRECTORIES = SemanticDiscovery::IGNORED_DIRECTORIES

    attr_reader :root, :output_path

    def initialize(root:, output_path: nil, registry_entries: nil, models: nil)
      @root = Pathname(root).expand_path
      @output_path = resolve_output_path(output_path)
      @registry_entries = registry_entries
      @models = models
    end

    def build
      entries = registry_entries
      graph = SemanticDiscovery.new(
        root: root,
        registry_entries: entries,
        models: @models
      ).call
      snapshot = SemanticSnapshot.new(
        graph: graph,
        generator_version: Maglev::VERSION,
        build_input_fingerprint: self.class.build_input_fingerprint(root),
        registry_compatibility_fingerprint:
          self.class.registry_compatibility_fingerprint(entries)
      )
      yaml = snapshot.to_yaml
      SemanticSnapshot.load(yaml)
      publish(yaml)
      snapshot
    end

    def validate
      SemanticSnapshot.load(output_path.binread)
    end

    def self.build_input_fingerprint(root)
      root = Pathname(root).expand_path
      digest = Digest::SHA256.new
      input_files(root).each do |path|
        relative = path.relative_path_from(root).to_s
        contents = path.binread
        digest << [relative.bytesize].pack("Q>") << relative
        digest << [contents.bytesize].pack("Q>") << contents
      end
      "sha256:#{digest.hexdigest}"
    end

    def self.registry_compatibility_fingerprint(entries)
      document = entries.sort_by(&:identifier).map do |entry|
        {
          identifier: entry.identifier,
          model: entry.model_class.name,
          queryable: normalize(entry.queryable)
        }
      end
      "sha256:#{Digest::SHA256.hexdigest(JSON.generate(document))}"
    end

    def self.input_files(root)
      root.glob(SemanticDiscovery::RUBY_GLOB).reject do |path|
        path.each_filename.any? { |part| IGNORED_DIRECTORIES.include?(part) }
      end.sort_by { |path| path.relative_path_from(root).to_s }
    end
    private_class_method :input_files

    def self.normalize(value)
      case value
      when Struct
        value.each_pair.to_h { |name, item| [name.to_s, normalize(item)] }
      when Hash
        value.keys.sort_by(&:to_s).to_h { |key| [key.to_s, normalize(value.fetch(key))] }
      when Array
        value.map { |item| normalize(item) }
      when Symbol
        value.to_s
      when Class, Module
        value.name
      else
        value
      end
    end
    private_class_method :normalize

    private

    def registry_entries
      @registry_entries || Registry.entries
    end

    def resolve_output_path(path)
      candidate = path || DEFAULT_PATH
      candidate = root.join(candidate) unless Pathname(candidate).absolute?
      Pathname(candidate).expand_path
    end

    def publish(yaml)
      FileUtils.mkdir_p(output_path.dirname)
      temporary = Tempfile.new(
        [".#{output_path.basename}", ".tmp"],
        output_path.dirname.to_s,
        binmode: true
      )
      begin
        temporary.write(yaml)
        temporary.flush
        temporary.fsync
        SemanticSnapshot.load(Pathname(temporary.path).binread)
        temporary.close
        File.rename(temporary.path, output_path.to_s)
      ensure
        temporary.close!
      end
    end
  end
end
