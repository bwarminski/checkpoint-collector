# ABOUTME: Parses `bin/fixture` arguments and dispatches work to fixture-specific classes.
# ABOUTME: Keeps the top-level CLI stable while fixture implementations live under `fixtures/`.
require "optparse"
require_relative "manifest"

module Fixtures
  class Command
    USAGE = "Usage: bin/fixture <name> <reset|drive|assert|all> [flags]".freeze
    VALID_VERBS = %w[reset drive assert all].freeze

    def initialize(argv:, registry: nil, manifest_loader: Fixtures::Manifest, stdout:, stderr:)
      @argv = argv.dup
      @registry = registry || default_registry
      @manifest_loader = manifest_loader
      @stdout = stdout
      @stderr = stderr
    end

    def run
      fixture_name = @argv.shift
      verb = @argv.shift
      return usage_error if fixture_name.nil? || verb.nil? || !VALID_VERBS.include?(verb)

      manifest = @manifest_loader.load(fixture_name)
      options = parse_flags(manifest: manifest)

      steps = verb == "all" ? %w[reset drive assert] : [verb]
      steps.each do |step|
        handler = @registry[[fixture_name, step]]
        return usage_error if handler.nil?

        handler.call(manifest: manifest, options: options)
      end

      0
    rescue OptionParser::ParseError => error
      @stderr.puts(error.message)
      usage_error
    rescue StandardError => error
      @stderr.puts(error.message)
      1
    end

    private

    def usage_error
      @stderr.puts(USAGE)
      1
    end

    def default_registry
      {
        ["missing-index", "reset"] => ->(manifest:, options:) do
          require File.expand_path("../../../fixtures/missing-index/setup/reset", __dir__)
          Fixtures::MissingIndex::Reset.new(manifest: manifest, options: options).run
        end,
        ["missing-index", "drive"] => ->(manifest:, options:) do
          require File.expand_path("../../../fixtures/missing-index/load/drive", __dir__)
          Fixtures::MissingIndex::Drive.new(manifest: manifest, options: options).run
        end,
        ["missing-index", "assert"] => ->(manifest:, options:) do
          require File.expand_path("../../../fixtures/missing-index/validate/assert", __dir__)
          Fixtures::MissingIndex::Assert.new(manifest: manifest, options: options, stdout: @stdout).run
        end,
      }
    end

    def parse_flags(manifest:)
      options = {
        base_url: ENV.fetch("BASE_URL", "http://localhost:3000"),
        admin_url: ENV.fetch("FIXTURE_ADMIN_URL", "postgresql://postgres:postgres@localhost:5432/postgres"),
        clickhouse_url: ENV.fetch("CLICKHOUSE_URL", "http://localhost:8123"),
        seconds: manifest.seconds,
        concurrency: manifest.concurrency,
        rate: manifest.rate,
        timeout_seconds: 180,
        rebuild_template: false,
      }

      OptionParser.new do |parser|
        parser.on("--rebuild-template") { options[:rebuild_template] = true }
        parser.on("--seconds N", Integer) { |value| options[:seconds] = value }
        parser.on("--concurrency N", Integer) { |value| options[:concurrency] = value }
        parser.on("--rate VALUE") do |value|
          options[:rate] = value == "unlimited" ? "unlimited" : Integer(value)
        rescue ArgumentError
          raise OptionParser::InvalidArgument, value
        end
        parser.on("--base-url URL") { |value| options[:base_url] = value }
        parser.on("--timeout-seconds N", Integer) { |value| options[:timeout_seconds] = value }
      end.parse!(@argv)

      options
    end
  end
end
