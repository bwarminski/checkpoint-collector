# ABOUTME: Parses the load runner CLI and loads workload files.
# ABOUTME: Keeps argument handling separate from runner orchestration.
require "optparse"
require "tmpdir"

module Load
  class CLI
    USAGE = "Usage: bin/load run --workload PATH --adapter PATH --app-root PATH [--readiness-path /up|none] [--startup-grace-seconds 15]".freeze

    def initialize(argv:, runner: nil, stdout: $stdout, stderr: $stderr)
      @argv = argv.dup
      @runner = runner || default_runner
      @stdout = stdout
      @stderr = stderr
    end

    def run
      command = @argv.shift
      return usage_error unless command == "run"

      options = parse_options
      workload = load_workload(options.fetch(:workload))
      runner = @runner.call(
        workload: workload,
        adapter_bin: options.fetch(:adapter_bin),
        app_root: options.fetch(:app_root),
        runs_dir: options.fetch(:runs_dir),
        readiness_path: options.fetch(:readiness_path),
        startup_grace_seconds: options.fetch(:startup_grace_seconds),
        stdout: @stdout,
        stderr: @stderr,
      )
      runner.run
    rescue OptionParser::ParseError, ArgumentError => error
      @stderr.puts(error.message)
      usage_error
    rescue StandardError => error
      @stderr.puts(error.message)
      2
    end

    private

    def default_runner
      lambda do |workload:, adapter_bin:, app_root:, runs_dir:, readiness_path:, startup_grace_seconds:, stdout:, stderr:|
        run_dir = File.join(runs_dir, "#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}-#{workload.name}")
        run_record = Load::RunRecord.new(run_dir:)
        adapter_client = Load::AdapterClient.new(adapter_bin:)
        Load::Runner.new(
          workload:,
          adapter_client:,
          run_record:,
          clock: -> { Time.now.utc },
          sleeper: ->(seconds) { sleep(seconds) },
          readiness_path:,
          startup_grace_seconds:,
          app_root:,
          adapter_bin:,
        )
      end
    end

    def parse_options
      options = {
        runs_dir: "runs",
        readiness_path: "/up",
        startup_grace_seconds: 15.0,
      }

      parser = OptionParser.new do |parser|
        parser.on("--workload PATH") { |value| options[:workload] = value }
        parser.on("--adapter PATH") { |value| options[:adapter_bin] = value }
        parser.on("--app-root PATH") { |value| options[:app_root] = value }
        parser.on("--runs-dir DIR") { |value| options[:runs_dir] = value }
        parser.on("--readiness-path PATH") { |value| options[:readiness_path] = value == "none" ? "none" : value }
        parser.on("--startup-grace-seconds N", Float) { |value| options[:startup_grace_seconds] = value }
      end
      parser.parse!(@argv)

      raise OptionParser::ParseError, "missing --workload" unless options[:workload]
      raise OptionParser::ParseError, "missing --adapter" unless options[:adapter_bin]
      raise OptionParser::ParseError, "missing --app-root" unless options[:app_root]
      raise OptionParser::ParseError, "workload file not found: #{options[:workload]}" unless File.exist?(options[:workload])

      options
    end

    def load_workload(path)
      absolute_path = File.expand_path(path)
      load absolute_path

      subclasses = ObjectSpace.each_object(Class).select do |klass|
        klass < Load::Workload &&
          klass.instance_methods(false).include?(:name) &&
          klass.instance_method(:name).source_location&.first == absolute_path
      end

      raise StandardError, "expected exactly one Load::Workload subclass in #{path}" unless subclasses.length == 1

      subclasses.first.new
    end

    def usage_error
      @stderr.puts(USAGE)
      2
    end
  end
end
