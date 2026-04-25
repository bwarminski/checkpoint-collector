# ABOUTME: Parses the load runner CLI and resolves named workloads.
# ABOUTME: Keeps command handling separate from runner orchestration.
require "optparse"
require "tmpdir"

module Load
  class CLI
    USAGE = "Usage: bin/load run|soak|verify-fixture --workload NAME --adapter PATH --app-root PATH [--readiness-path /up|none] [--startup-grace-seconds 15] [--metrics-interval-seconds 5]".freeze

    def initialize(argv:, version:, runner_factory: nil, verifier_factory: nil, stop_flag: nil, stdout: $stdout, stderr: $stderr)
      @argv = argv.dup
      @version = version
      @verifier_factory = verifier_factory || default_verifier_factory
      @runner_factory = runner_factory || default_runner_factory
      @stop_flag = stop_flag || Load::Runner::InternalStopFlag.new
      @stdout = stdout
      @stderr = stderr
    end

    def run
      command = @argv.shift

      case command
      when "run"
        run_command(mode: :finite)
      when "soak"
        run_command(mode: :continuous)
      when "verify-fixture"
        verify_fixture_command
      when "--help", "-h", nil
        @stdout.puts(USAGE)
        Load::ExitCodes::SUCCESS
      when "--version", "-v"
        @stdout.puts(@version)
        Load::ExitCodes::SUCCESS
      else
        @stderr.puts("unknown command: #{command}")
        usage_error
      end
    rescue Load::FixtureVerifier::VerificationError => error
      @stderr.puts(error.message)
      Load::ExitCodes::ADAPTER_ERROR
    rescue OptionParser::ParseError, ArgumentError => error
      @stderr.puts(error.message)
      usage_error
    rescue StandardError => error
      @stderr.puts(error.message)
      Load::ExitCodes::USAGE_ERROR
    end

    private

    def run_command(mode:)
      options = parse_run_options
      workload = load_workload(options.fetch(:workload))
      runner = @runner_factory.call(
        workload: workload,
        mode: mode,
        adapter_bin: options.fetch(:adapter_bin),
        app_root: options.fetch(:app_root),
        runs_dir: options.fetch(:runs_dir),
        readiness_path: options.fetch(:readiness_path),
        startup_grace_seconds: options.fetch(:startup_grace_seconds),
        metrics_interval_seconds: options.fetch(:metrics_interval_seconds),
        stop_flag: @stop_flag,
        stdout: @stdout,
        stderr: @stderr,
      )
      runner.run
    end

    def verify_fixture_command
      options = parse_shared_options
      verifier = @verifier_factory.call(
        workload_name: options.fetch(:workload),
        adapter_bin: options.fetch(:adapter_bin),
        app_root: options.fetch(:app_root),
        stdout: @stdout,
        stderr: @stderr,
      )
      raise ArgumentError, "unknown workload: #{options.fetch(:workload)}" unless verifier

      verifier.call
    end

    def default_runner_factory
      lambda do |workload:, adapter_bin:, app_root:, runs_dir:, readiness_path:, startup_grace_seconds:, metrics_interval_seconds:, stop_flag:, stdout:, stderr:, mode:|
        run_dir = File.join(runs_dir, "#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}-#{workload.name}")
        run_record = Load::RunRecord.new(run_dir:)
        adapter_client = Load::AdapterClient.new(adapter_bin:, run_record:)
        verifier = nil
        if fixture_verification_required?(workload_name: workload.name, mode:)
          verifier = @verifier_factory.call(
            workload_name: workload.name,
            adapter_bin:,
            app_root:,
            stdout:,
            stderr:,
          )
        end
        Load::Runner.new(
          workload:,
          adapter_client:,
          run_record:,
          clock: -> { Time.now.utc },
          sleeper: ->(seconds) { sleep(seconds) },
          readiness_path:,
          startup_grace_seconds:,
          metrics_interval_seconds:,
          workload_file: workload_path(workload.name),
          app_root:,
          adapter_bin:,
          stop_flag:,
          verifier:,
        )
      end
    end

    def default_verifier_factory
      lambda do |workload_name:, adapter_bin:, app_root:, stdout:, stderr:|
        next unless workload_name == "missing-index-todos"

        Load::FixtureVerifier.new(
          workload_name:,
          adapter_bin:,
          app_root:,
          stdout:,
          stderr:,
          database_url: ENV["DATABASE_URL"],
          pg: PG,
        )
      end
    end

    def parse_shared_options
      options = {
      }

      parser = OptionParser.new do |parser|
        parser.on("--workload NAME") { |value| options[:workload] = value }
        parser.on("--adapter PATH") { |value| options[:adapter_bin] = value }
        parser.on("--app-root PATH") { |value| options[:app_root] = value }
      end
      parser.parse!(@argv)

      raise OptionParser::ParseError, "missing --workload" unless options[:workload]
      raise OptionParser::ParseError, "missing --adapter" unless options[:adapter_bin]
      raise OptionParser::ParseError, "missing --app-root" unless options[:app_root]

      options
    end

    def parse_run_options
      options = {
        runs_dir: "runs",
        readiness_path: "/up",
        startup_grace_seconds: 15.0,
        metrics_interval_seconds: 5.0,
      }

      parser = OptionParser.new do |parser|
        parser.on("--workload NAME") { |value| options[:workload] = value }
        parser.on("--adapter PATH") { |value| options[:adapter_bin] = value }
        parser.on("--app-root PATH") { |value| options[:app_root] = value }
        parser.on("--runs-dir DIR") { |value| options[:runs_dir] = value }
        parser.on("--readiness-path PATH") { |value| options[:readiness_path] = value == "none" ? nil : value }
        parser.on("--startup-grace-seconds N", Float) { |value| options[:startup_grace_seconds] = value }
        parser.on("--metrics-interval-seconds N", Float) { |value| options[:metrics_interval_seconds] = value }
      end
      parser.parse!(@argv)

      raise OptionParser::ParseError, "missing --workload" unless options[:workload]
      raise OptionParser::ParseError, "missing --adapter" unless options[:adapter_bin]
      raise OptionParser::ParseError, "missing --app-root" unless options[:app_root]

      options
    end

    def load_workload(name)
      Load::WorkloadRegistry.fetch(name).new
    rescue Load::WorkloadRegistry::Error
      begin
        require workload_path(name)
      rescue LoadError
        raise ArgumentError, "unknown workload: #{name}"
      end
      Load::WorkloadRegistry.fetch(name).new
    rescue Load::WorkloadRegistry::Error
      raise ArgumentError, "unknown workload: #{name}"
    end

    def usage_error
      @stderr.puts(USAGE)
      Load::ExitCodes::USAGE_ERROR
    end

    def fixture_verification_required?(workload_name:, mode:)
      workload_name == "missing-index-todos" && %i[finite continuous].include?(mode)
    end

    def workload_path(name)
      File.expand_path("../../../workloads/#{name.tr("-", "_")}/workload", __dir__)
    end
  end
end
