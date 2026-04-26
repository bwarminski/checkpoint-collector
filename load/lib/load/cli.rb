# ABOUTME: Parses the load runner CLI and resolves named workloads.
# ABOUTME: Keeps command handling separate from runner orchestration.
require "optparse"
require "net/http"
require "tmpdir"

module Load
  class CLI
    VerifierError = Class.new(StandardError)
    USAGE = <<~USAGE.freeze
      Usage: bin/load run|soak --workload NAME --adapter PATH --app-root PATH [--readiness-path /up|none] [--startup-grace-seconds 15] [--metrics-interval-seconds 5] [--invariants enforce|warn|off]
             bin/load verify-fixture --workload NAME --adapter PATH --app-root PATH
    USAGE

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
    rescue Load::VerificationError => error
      @stderr.puts(error.message)
      Load::ExitCodes::ADAPTER_ERROR
    rescue VerifierError, Load::AdapterClient::AdapterError, Load::ReadinessGate::Timeout => error
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
      run_dir = File.join(options.fetch(:runs_dir), "#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}-#{workload.name}")
      run_record = Load::RunRecord.new(run_dir:)
      adapter_client = Load::AdapterClient.new(adapter_bin: options.fetch(:adapter_bin), run_record:)
      verifier = build_verifier(
        workload:,
        adapter_bin: options.fetch(:adapter_bin),
        app_root: options.fetch(:app_root),
        stdout: @stdout,
        stderr: @stderr,
      )
      runtime = Load::Runner::Runtime.new(
        -> { Time.now.utc },
        ->(seconds) { sleep(seconds) },
        Net::HTTP,
        @stop_flag,
      )
      config = Load::Runner::Config.new(
        readiness_path: options.fetch(:readiness_path),
        startup_grace_seconds: options.fetch(:startup_grace_seconds),
        metrics_interval_seconds: options.fetch(:metrics_interval_seconds),
        workload_file: workload_path(workload.name),
        app_root: options.fetch(:app_root),
        adapter_bin: options.fetch(:adapter_bin),
        mode: mode,
        verifier: verifier,
      )
      invariant_config = Load::Runner::InvariantConfig.new(
        policy: options.fetch(:invariant_policy),
      )
      runner = @runner_factory.call(
        workload: workload,
        adapter_client: adapter_client,
        run_record: run_record,
        runtime: runtime,
        config: config,
        invariant_config: invariant_config,
        stderr: @stderr,
      )
      runner.run
    end

    def verify_fixture_command
      options = parse_shared_options
      workload = load_workload(options.fetch(:workload))
      verifier = build_verifier(
        workload:,
        adapter_bin: options.fetch(:adapter_bin),
        app_root: options.fetch(:app_root),
        stdout: @stdout,
        stderr: @stderr,
      )
      raise ArgumentError, "unknown workload: #{options.fetch(:workload)}" unless verifier

      verify_fixture(workload:, verifier:, options:)
    end

    def default_runner_factory
      ->(**kwargs) { Load::Runner.new(**kwargs) }
    end

    def default_verifier_factory
      lambda do |workload:, adapter_bin:, app_root:, stdout:, stderr:|
        workload.verifier(database_url: ENV["DATABASE_URL"], pg: PG)
      end
    end

    def build_verifier(workload:, adapter_bin:, app_root:, stdout:, stderr:)
      verifier = @verifier_factory.call(
        workload:,
        adapter_bin:,
        app_root:,
        stdout:,
        stderr:,
      )
      return nil if verifier.nil?
      return verifier if verifier.respond_to?(:call)

      raise VerifierError, "verifier must respond to call"
    rescue Load::VerificationError
      raise
    rescue StandardError => error
      raise VerifierError, error.message
    end

    def verify_fixture(workload:, verifier:, options:)
      adapter_client = nil
      pid = nil
      failure = nil
      adapter_client = Load::AdapterClient.new(adapter_bin: options.fetch(:adapter_bin))
      adapter_client.describe
      adapter_client.prepare(app_root: options.fetch(:app_root))
      adapter_client.reset_state(app_root: options.fetch(:app_root), workload: workload.name, scale: workload.scale)
      start_response = adapter_client.start(app_root: options.fetch(:app_root))
      base_url = start_response.fetch("base_url")
      pid = start_response.fetch("pid")
      Load::ReadinessGate.new(
        base_url:,
        readiness_path: "/up",
        startup_grace_seconds: 15.0,
        clock: -> { Time.now.utc },
        sleeper: ->(seconds) { sleep(seconds) },
        http: Net::HTTP,
      ).call
      verifier.call(base_url:)
      Load::ExitCodes::SUCCESS
    rescue Load::VerificationError => error
      failure = error
      raise
    rescue StandardError => error
      failure = error
      raise VerifierError, error.message
    ensure
      begin
        adapter_client&.stop(pid:) if pid
      rescue StandardError
        raise unless failure
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
        invariant_policy: :enforce,
      }

      parser = OptionParser.new do |parser|
        parser.on("--workload NAME") { |value| options[:workload] = value }
        parser.on("--adapter PATH") { |value| options[:adapter_bin] = value }
        parser.on("--app-root PATH") { |value| options[:app_root] = value }
        parser.on("--runs-dir DIR") { |value| options[:runs_dir] = value }
        parser.on("--readiness-path PATH") { |value| options[:readiness_path] = value == "none" ? nil : value }
        parser.on("--startup-grace-seconds N", Float) { |value| options[:startup_grace_seconds] = value }
        parser.on("--metrics-interval-seconds N", Float) { |value| options[:metrics_interval_seconds] = value }
        parser.on("--invariants POLICY") { |value| options[:invariant_policy] = parse_invariant_policy(value) }
      end
      parser.parse!(@argv)

      raise OptionParser::ParseError, "missing --workload" unless options[:workload]
      raise OptionParser::ParseError, "missing --adapter" unless options[:adapter_bin]
      raise OptionParser::ParseError, "missing --app-root" unless options[:app_root]

      options
    end

    def parse_invariant_policy(value)
      policy = value.to_sym
      return policy if %i[enforce warn off].include?(policy)

      raise OptionParser::ParseError, "invalid option: --invariants #{value}"
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

    def workload_path(name)
      File.expand_path("../../../workloads/#{name.tr("-", "_")}/workload", __dir__)
    end
  end
end
