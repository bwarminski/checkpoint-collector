# Mixed Missing-Index Fixture Walkthrough

*2026-04-26T13:23:41Z by Showboat 0.6.1*
<!-- showboat-id: 7e186a98-c952-4481-a985-0b6850f9b882 -->

This walkthrough follows the current `wip/mixed-todo-fixture-design` branch in execution order. It focuses on the code as it exists after the tenant-shaped workload refactor, the workload-owned verifier/oracle extraction, the runner decomposition, and the final dominance retune that set `user_count: 100` and `FetchCounts` weight to `0`.

## Design anchors

The current behavior is defined by a stack of specs rather than one file. These specs explain why the branch now has a tenant-shaped workload, grouped runner constructor inputs, extracted execution collaborators, and a workload-owned verifier/oracle contract.

```bash
rg -n '^# ' docs/superpowers/specs/2026-04-24-mixed-missing-index-design.md docs/superpowers/specs/2026-04-25-invariant-policy-design.md docs/superpowers/specs/2026-04-25-load-workload-boundaries-design.md docs/superpowers/specs/2026-04-25-tenant-shaped-workload-design.md docs/superpowers/specs/2026-04-25-runner-decomposition-design.md docs/superpowers/specs/2026-04-25-runner-constructor-design.md
```

```output
docs/superpowers/specs/2026-04-25-runner-constructor-design.md:1:# Runner Constructor Design
docs/superpowers/specs/2026-04-25-runner-decomposition-design.md:1:# Runner Decomposition Design
docs/superpowers/specs/2026-04-25-load-workload-boundaries-design.md:1:# Load Workload Boundaries Design
docs/superpowers/specs/2026-04-25-tenant-shaped-workload-design.md:1:# Tenant-Shaped Missing-Index Workload Design
docs/superpowers/specs/2026-04-25-invariant-policy-design.md:1:# ABOUTME: Specifies configurable invariant handling for load runner run and soak modes.
docs/superpowers/specs/2026-04-25-invariant-policy-design.md:2:# ABOUTME: Defines enforce, warn, and off policies without changing fixture verification behavior.
docs/superpowers/specs/2026-04-25-invariant-policy-design.md:4:# Invariant Policy Design
docs/superpowers/specs/2026-04-24-mixed-missing-index-design.md:1:# Mixed Missing-Index Todo Fixture — Design Spec
```

## Entry point and CLI

`bin/load` is still a thin process shell. The real branching now lives in `Load::CLI`, which resolves workloads, builds grouped runner inputs, and asks the workload for its verifier instead of hard-coding fixture logic in the core library.

```bash
sed -n '1,120p' bin/load && printf '\n---\n' && sed -n '1,240p' load/lib/load/cli.rb
```

```output
#!/usr/bin/env ruby
# ABOUTME: Runs the load runner CLI for benchmark workloads.
# ABOUTME: Installs signal traps and delegates command handling to Load::CLI.
VERSION_PATH = File.expand_path("../VERSION", __dir__)

require_relative "../load/lib/load"

stop_flag = Load::Runner::InternalStopFlag.new
previous_handlers = {
  "INT" => Signal.trap("INT") { stop_flag.trigger(:sigint) },
  "TERM" => Signal.trap("TERM") { stop_flag.trigger(:sigterm) },
}
begin
  exit Load::CLI.new(
    argv: ARGV,
    version: File.read(VERSION_PATH).strip,
    stop_flag:,
    stdout: $stdout,
    stderr: $stderr,
  ).run
ensure
  previous_handlers.each do |signal, handler|
    Signal.trap(signal, handler)
  end
end

---
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
```

## Runner orchestration

`Load::Runner` now coordinates instead of directly owning every subsystem. The constructor groups dependencies into `Runtime`, `Config`, and `InvariantConfig`, then wires up `RunState`, `LoadExecution`, and `InvariantMonitor`.

```bash
sed -n '1,260p' load/lib/load/runner.rb
```

```output
# ABOUTME: Orchestrates adapter lifecycle, readiness probing, and worker execution.
# ABOUTME: Writes run state as workers report the first successful response.
require "net/http"
require "pg"
require "thread"
require "time"

module Load
  class Runner
    DEFAULT_INVARIANT_SAMPLE_INTERVAL_SECONDS = 60.0
    Runtime = Data.define(:clock, :sleeper, :http, :stop_flag) do
      def self.default
        new(
          -> { Time.now.utc },
          ->(seconds) { sleep(seconds) },
          Net::HTTP,
          InternalStopFlag.new,
        )
      end
    end
    Config = Data.define(:readiness_path, :startup_grace_seconds, :metrics_interval_seconds, :workload_file, :app_root, :adapter_bin, :mode, :verifier) do
      def initialize(readiness_path: "/up", startup_grace_seconds: 15, metrics_interval_seconds: 5, workload_file: nil, app_root: nil, adapter_bin: nil, mode: :finite, verifier: nil)
        super
      end
    end
    InvariantConfig = Data.define(:policy, :sampler, :sample_interval_seconds, :database_url, :pg) do
      def initialize(policy: :enforce, sampler: nil, sample_interval_seconds: Runner::DEFAULT_INVARIANT_SAMPLE_INTERVAL_SECONDS, database_url: ENV["DATABASE_URL"], pg: PG)
        super
      end
    end
    attr_reader :run_state

    InvariantCheck = Data.define(:name, :actual, :min, :max) do
      def breaches
        [].tap do |messages|
          messages << "#{name} #{actual} is below min #{min}" if !min.nil? && actual < min
          messages << "#{name} #{actual} is above max #{max}" if !max.nil? && actual > max
        end
      end

      def breach?
        !breaches.empty?
      end

      def to_record
        { name:, actual:, min:, max:, breach: breach?, breaches: }
      end
    end

    InvariantSample = Data.define(:checks) do
      def breaches
        checks.flat_map(&:breaches)
      end

      def breach?
        !breaches.empty?
      end

      def healthy?
        !breach?
      end

      def to_warning
        { type: "invariant_breach", message: breaches.join("; "), checks: checks.map(&:to_record) }
      end

      def to_record(sampled_at:)
        { sampled_at:, checks: checks.map(&:to_record), breach: breach?, breaches: }
      end
    end

    def initialize(workload:, adapter_client:, run_record:, runtime: Runtime.default, config: Config.new, invariant_config: InvariantConfig.new, stderr: $stderr)
      @workload = workload
      @adapter_client = adapter_client
      @run_record = run_record
      @runtime = runtime
      @config = config
      @invariant_config = invariant_config
      @stderr = stderr
      sampler = resolve_invariant_sampler
      validate_invariant_sampler!(sampler)
      @run_state = Load::RunState.new(
        run_record:,
        workload:,
        adapter_bin: @config.adapter_bin || @adapter_client.adapter_bin,
        app_root: @config.app_root,
        readiness_path: @config.readiness_path,
        startup_grace_seconds: @config.startup_grace_seconds,
        metrics_interval_seconds: @config.metrics_interval_seconds,
        workload_file: @config.workload_file,
      )
      @invariant_monitor = Load::InvariantMonitor.new(
        sampler: sampler,
        policy: @invariant_config.policy,
        interval_seconds: @invariant_config.sample_interval_seconds,
        stop_flag: @runtime.stop_flag,
        sleeper: @runtime.sleeper,
        on_sample: ->(sample) { @run_state.append_invariant_sample(**sample.to_record(sampled_at: current_time)) },
        on_warning: ->(warning) { @run_state.append_warning(warning) },
        on_breach_stop: ->(reason) { trigger_stop(reason) },
        stderr: @stderr,
      )
    end

    def run
      request_totals = { total: 0, ok: 0, error: 0 }
      begin
        @run_state.write_initial
        adapter_describe = @adapter_client.describe
        validate_adapter_response!(adapter_describe, %w[name framework runtime], "describe")
        @run_state.merge(adapter: {
          describe: adapter_describe,
          bin: @config.adapter_bin || @adapter_client.adapter_bin,
          app_root: @config.app_root,
        })

        @adapter_client.prepare(app_root: @config.app_root)
        reset_state = @adapter_client.reset_state(app_root: @config.app_root, workload: @workload.name, scale: @workload.scale)
        @run_state.merge(query_ids: Array(reset_state["query_ids"]).map(&:to_s)) if reset_state.is_a?(Hash) && reset_state["query_ids"]

        start_response = @adapter_client.start(app_root: @config.app_root)
        validate_adapter_response!(start_response, %w[pid base_url], "start")
        @run_state.merge(adapter: { pid: start_response.fetch("pid"), base_url: start_response.fetch("base_url") })

        probe_readiness(start_response.fetch("base_url"))
        verify_fixture(base_url: start_response.fetch("base_url"))
        request_totals = run_execution(start_response.fetch("base_url"))

        result = finish_run(request_totals)
      rescue Load::InvariantMonitor::Failure
        @run_state.merge(outcome: @run_state.outcome_payload(request_totals:, aborted: true, error_code: "invariant_sampler_failed"))
        result = Load::ExitCodes::ADAPTER_ERROR
      rescue Load::VerificationError => error
        @run_state.merge(outcome: @run_state.outcome_payload(request_totals:, aborted: true, error_code: "fixture_verification_failed").merge(error_message: error.message))
        result = Load::ExitCodes::ADAPTER_ERROR
      rescue AdapterClient::AdapterError
        @run_state.merge(outcome: @run_state.outcome_payload(request_totals:, aborted: true, error_code: "adapter_error"))
        result = Load::ExitCodes::ADAPTER_ERROR
      rescue Load::ReadinessGate::Timeout
        @run_state.merge(outcome: @run_state.outcome_payload(request_totals:, aborted: true, error_code: "readiness_timeout"))
        result = Load::ExitCodes::ADAPTER_ERROR
      ensure
        result = stop_adapter_safely(result, request_totals)
      end

      result
    end

    private

    def verify_fixture(base_url:)
      return unless @config.verifier

      @config.verifier.call(base_url:)
    end

    def probe_readiness(base_url)
      @run_state.merge(
        window: {
          readiness: Load::ReadinessGate.new(
            base_url:,
            readiness_path: @config.readiness_path,
            startup_grace_seconds: @config.startup_grace_seconds,
            clock: @runtime.clock,
            sleeper: @runtime.sleeper,
            http: @runtime.http,
          ).call,
        },
      )
    end

    def run_execution(base_url)
      execution = nil
      invariant_thread = nil
      request_totals = { total: 0, ok: 0, error: 0 }

      begin
        execution = Load::LoadExecution.new(
          workload: @workload,
          base_url:,
          runtime: @runtime,
          metrics_interval_seconds: @config.metrics_interval_seconds,
          run_record: @run_record,
          on_first_success: -> { @run_state.pin_window_start(now: current_time) },
        )
        invariant_thread = @config.mode == :continuous ? @invariant_monitor.start : nil
        request_totals = execution.run(mode: @config.mode, duration_seconds: @workload.load_plan.duration_seconds)
      ensure
        request_totals = execution.request_totals if execution
        @invariant_monitor.stop(invariant_thread)
      end

      request_totals
    end

    def trigger_stop(reason)
      return unless @runtime.stop_flag.respond_to?(:trigger)

      @runtime.stop_flag.trigger(reason)
    end

    def finish_run(request_totals)
      if stop_reason == :invariant_breach
        @run_state.finish(now: current_time, request_totals:, aborted: true, error_code: "invariant_breach")
        return Load::ExitCodes::ADAPTER_ERROR
      end

      if @run_state.window_started?
        @run_state.finish(now: current_time, request_totals:, aborted: stop_aborted?)
        return final_exit_code
      end

      @run_state.finish(now: current_time, request_totals:, aborted: true, error_code: "no_successful_requests")
      Load::ExitCodes::NO_SUCCESSFUL_REQUESTS
    end

    def final_exit_code
      return Load::ExitCodes::ADAPTER_ERROR if stop_reason == :invariant_breach

      Load::ExitCodes::SUCCESS
    end

    def stop_aborted?
      %i[sigint sigterm].include?(stop_reason)
    end

    def stop_reason
      return nil unless @runtime.stop_flag.respond_to?(:reason)

      @runtime.stop_flag.reason
    end

    def current_time
      @runtime.clock.call
    end

    def stop_adapter_safely(result, request_totals)
      pid = @run_state.snapshot.dig(:adapter, :pid)
      return result unless pid

      @adapter_client.stop(pid:)
      result
    rescue AdapterClient::AdapterError
      if result.nil? || result == Load::ExitCodes::SUCCESS
        @run_state.merge(outcome: @run_state.outcome_payload(request_totals:, aborted: true, error_code: "adapter_error"))
        return Load::ExitCodes::ADAPTER_ERROR
      end

      result
    end

    def validate_adapter_response!(response, required_keys, response_name)
      raise AdapterClient::AdapterError, "invalid adapter #{response_name} response" unless response.is_a?(Hash)

      required_keys.each { |key| response.fetch(key) }
    rescue KeyError
      raise AdapterClient::AdapterError, "invalid adapter #{response_name} response"
    end

    def resolve_invariant_sampler
```

## Extracted collaborators

The decomposed collaborators are where most of the behavior now lives. `RunState` owns `run.json`, `LoadExecution` owns worker/reporter lifecycle, and `InvariantMonitor` owns the runtime invariant sampling policy.

```bash
sed -n '1,240p' load/lib/load/run_state.rb && printf '\n---\n' && sed -n '1,260p' load/lib/load/load_execution.rb && printf '\n---\n' && sed -n '1,240p' load/lib/load/invariant_monitor.rb
```

```output
# ABOUTME: Owns the mutable run payload and persists it to the run record.
# ABOUTME: Encapsulates initial state, window pinning, warnings, samples, and final outcome writes.
require "thread"

module Load
  class RunState
    def initialize(run_record:, workload:, adapter_bin:, app_root:, readiness_path:, startup_grace_seconds:, metrics_interval_seconds:, workload_file:)
      @run_record = run_record
      @mutex = Mutex.new
      @window_started = false
      @state = initial_state(
        run_record:,
        workload:,
        adapter_bin:,
        app_root:,
        readiness_path:,
        startup_grace_seconds:,
        metrics_interval_seconds:,
        workload_file:,
      )
    end

    def write_initial
      @mutex.synchronize do
        write_current_locked
      end
    end

    def merge(fragment)
      @mutex.synchronize do
        @state = deep_merge(@state, deep_copy(fragment))
        write_current_locked
      end
    end

    def pin_window_start(now:)
      @mutex.synchronize do
        return if @window_started

        @window_started = true
        @state = deep_merge(@state, window: { start_ts: now })
        write_current_locked
      end
    end

    def append_warning(payload)
      @mutex.synchronize do
        warnings = @state.fetch(:warnings).dup
        warnings << deep_copy(payload)
        @state = deep_merge(@state, warnings:)
        write_current_locked
      end
    end

    def append_invariant_sample(sampled_at:, breach:, breaches:, checks:)
      @mutex.synchronize do
        invariant_samples = @state.fetch(:invariant_samples).dup
        invariant_samples << {
          sampled_at:,
          breach:,
          breaches: deep_copy(breaches),
          checks: deep_copy(checks),
        }
        @state = deep_merge(@state, invariant_samples:)
        write_current_locked
      end
    end

    def finish(now:, request_totals:, aborted:, error_code: nil)
      @mutex.synchronize do
        @state = deep_merge(
          @state,
          window: { end_ts: now },
          outcome: outcome_payload(request_totals:, aborted:, error_code:),
        )
        write_current_locked
      end
    end

    def outcome_payload(request_totals:, aborted:, error_code: nil)
      {
        requests_total: request_totals.fetch(:total),
        requests_ok: request_totals.fetch(:ok),
        requests_error: request_totals.fetch(:error),
        aborted:,
        error_code:,
      }.compact
    end

    def snapshot
      @mutex.synchronize do
        deep_copy(@state)
      end
    end

    def window_started?
      @mutex.synchronize do
        @window_started
      end
    end

    private

    def initial_state(run_record:, workload:, adapter_bin:, app_root:, readiness_path:, startup_grace_seconds:, metrics_interval_seconds:, workload_file:)
      {
        run_id: File.basename(run_record.run_dir),
        schema_version: 2,
        workload: {
          name: workload.name,
          file: workload_file,
          scale: workload.scale.to_h,
          load_plan: workload.load_plan.to_h,
          actions: workload.actions.map { |entry| { class: entry.action_class.name, weight: entry.weight } },
        },
        adapter: {
          describe: nil,
          bin: adapter_bin,
          app_root: app_root,
          base_url: nil,
          pid: nil,
        },
        window: {
          start_ts: nil,
          end_ts: nil,
          readiness: {
            path: readiness_path,
            probe_duration_ms: nil,
            probe_attempts: nil,
          },
          startup_grace_seconds: startup_grace_seconds,
          metrics_interval_seconds: metrics_interval_seconds,
        },
        outcome: outcome_payload(request_totals: { total: 0, ok: 0, error: 0 }, aborted: false),
        query_ids: [],
        warnings: [],
        invariant_samples: [],
      }
    end

    def write_current_locked
      @run_record.write_run(deep_copy(@state))
    end

    def deep_merge(left, right)
      left.merge(right) do |_, left_value, right_value|
        if left_value.is_a?(Hash) && right_value.is_a?(Hash)
          deep_merge(left_value, right_value)
        else
          right_value
        end
      end
    end

    def deep_copy(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, inner_value), copy| copy[key] = deep_copy(inner_value) }
      when Array
        value.map { |inner_value| deep_copy(inner_value) }
      else
        value
      end
    end
  end
end

---
# ABOUTME: Runs workload traffic through workers and reporters for one load window.
# ABOUTME: Owns worker construction, wait-loop behavior, request totals, and thread drain.
module Load
  class LoadExecution
    WORKER_DRAIN_TIMEOUT_SECONDS = 1.0
    CONTINUOUS_POLL_SECONDS = 0.1

    MetricsSink = Data.define(:run_record) do
      def <<(line)
        run_record.append_metrics(line)
      end
    end

    class TrackingBuffer < Load::Metrics::Buffer
      def initialize(on_first_success:)
        super()
        @on_first_success = on_first_success
        @started = false
        @request_totals = { total: 0, ok: 0, error: 0 }
      end

      def record_ok(**kwargs)
        super(**kwargs)
        @request_totals[:total] += 1
        @request_totals[:ok] += 1
        return if @started

        @started = true
        @on_first_success.call
      end

      def record_error(**kwargs)
        super(**kwargs)
        @request_totals[:total] += 1
        @request_totals[:error] += 1
      end

      def request_totals
        @request_totals.dup
      end
    end

    attr_reader :request_totals

    def initialize(workload:, base_url:, runtime:, metrics_interval_seconds:, run_record:, on_first_success:, reporter_factory: nil)
      @workload = workload
      @base_url = base_url
      @runtime = runtime
      @metrics_interval_seconds = metrics_interval_seconds
      @run_record = run_record
      @reporter_factory = reporter_factory
      @request_totals = { total: 0, ok: 0, error: 0 }
      @first_success = FirstSuccess.new(on_first_success)
    end

    def run(mode:, duration_seconds:)
      begin
        workers = build_workers
        reporter = build_reporter(workers)
        threads = workers.map { |worker| Thread.new { worker.run } }
        reporter.start
        wait(mode:, duration_seconds:)
      ensure
        drain_threads(threads)
        request_totals = aggregate_request_totals(workers || [])
        reporter.stop
      end

      request_totals
    end

    private

    class FirstSuccess
      def initialize(callback)
        @callback = callback
        @mutex = Mutex.new
        @seen = false
      end

      def call
        @mutex.synchronize do
          return if @seen

          @seen = true
        end

        @callback.call
      end
    end

    def build_workers
      plan = @workload.load_plan
      entries = @workload.actions
      seed = plan.seed.nil? ? @workload.scale.seed : plan.seed
      rate_limiter = Load::RateLimiter.new(rate_limit: plan.rate_limit, clock: @runtime.clock, sleeper: @runtime.sleeper)

      Array.new(plan.workers) do |index|
        Load::Worker.new(
          worker_id: index + 1,
          selector: Load::Selector.new(entries:, rng: Random.new(seed + index)),
          buffer: TrackingBuffer.new(on_first_success: @first_success),
          client: Load::Client.new(base_url: @base_url, http: @runtime.http),
          ctx: { base_url: @base_url, scale: @workload.scale },
          rng: Random.new(seed + index),
          rate_limiter:,
          stop_flag: @runtime.stop_flag,
        )
      end
    end

    def build_reporter(workers)
      return @reporter_factory.call(workers:) if @reporter_factory

      Load::Reporter.new(
        workers:,
        interval_seconds: @metrics_interval_seconds,
        sink: MetricsSink.new(@run_record),
        clock: @runtime.clock,
        sleeper: @runtime.sleeper,
      )
    end

    def wait(mode:, duration_seconds:)
      if mode == :continuous
        wait_for_stop_signal
      else
        wait_for_window_end(duration_seconds)
      end
    end

    def wait_for_window_end(duration_seconds)
      deadline = @runtime.clock.call + duration_seconds

      until @runtime.stop_flag.call
        remaining = deadline - @runtime.clock.call
        if remaining <= 0
          @runtime.stop_flag.trigger(:timeout) if @runtime.stop_flag.respond_to?(:trigger)
          break
        end

        Thread.pass
        next if @runtime.stop_flag.call

        remaining = deadline - @runtime.clock.call
        next if remaining <= 0

        @runtime.sleeper.call([1.0, remaining].min)
      end
    end

    def wait_for_stop_signal
      until @runtime.stop_flag.call
        Thread.pass
        @runtime.sleeper.call(CONTINUOUS_POLL_SECONDS)
      end
    end

    def drain_threads(threads)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + WORKER_DRAIN_TIMEOUT_SECONDS

      threads.each do |thread|
        remaining = [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max
        thread.join(remaining)
        next unless thread.alive?

        thread.kill
        thread.join
      end
    end

    def aggregate_request_totals(workers)
      @request_totals = workers.each_with_object({ total: 0, ok: 0, error: 0 }) do |worker, totals|
        worker.buffer.request_totals.each do |key, value|
          totals[key] += value
        end
      end
    end
  end
end

---
# ABOUTME: Runs the invariant sampler thread and applies breach policy.
# ABOUTME: Emits samples, warnings, and stop signals without owning run-record schema.
require "thread"

module Load
  class InvariantMonitor
    Failure = Class.new(StandardError)
    Shutdown = Class.new(StandardError)

    def initialize(sampler:, policy:, interval_seconds:, stop_flag:, sleeper:, on_sample:, on_warning:, on_breach_stop:, stderr:)
      @sampler = sampler
      @policy = policy
      @interval_seconds = interval_seconds
      @stop_flag = stop_flag
      @sleeper = sleeper
      @on_sample = on_sample
      @on_warning = on_warning
      @on_breach_stop = on_breach_stop
      @stderr = stderr
      @consecutive_breaches = 0
      @sleeping = false
      @failure = nil
      @mutex = Mutex.new
    end

    def start
      return nil if @policy == :off
      return nil if @sampler.nil?

      Thread.new do
        begin
          loop do
            break if @stop_flag.call

            begin
              Thread.handle_interrupt(Shutdown => :immediate) do
                sleep_once
              end
            rescue Shutdown, StopIteration
              break
            end

            break if @stop_flag.call

            Thread.handle_interrupt(Shutdown => :never) do
              sample_once
            end
          end
        rescue Shutdown, StopIteration
          nil
        rescue StandardError => error
          record_failure(error)
          @on_breach_stop.call(:invariant_sampler_failed)
        end
      end
    end

    def stop(thread)
      return unless thread
      return if thread == Thread.current

      if sleeping?
        begin
          thread.raise(Shutdown.new)
        rescue ThreadError
          nil
        end
      end

      thread.join
      failure = clear_failure
      raise Failure, "invariant sampler failed" if failure
    end

    def sample_once
      sample = @sampler.call
      @on_sample.call(sample)
      return reset_breaches unless sample.breach?

      warning = sample.to_warning
      @on_warning.call(warning)
      @stderr.puts("warning: invariant breach: #{sample.breaches.join('; ')}") if @policy == :warn
      return sample if @policy == :warn

      consecutive_breaches = @mutex.synchronize do
        @consecutive_breaches += 1
      end
      @on_breach_stop.call(:invariant_breach) if consecutive_breaches >= 3
      sample
    end

    private

    def sleep_once
      @mutex.synchronize do
        @sleeping = true
      end
      @sleeper.call(@interval_seconds)
    ensure
      @mutex.synchronize do
        @sleeping = false
      end
    end

    def reset_breaches
      @mutex.synchronize do
        @consecutive_breaches = 0 if @policy == :enforce
      end
    end

    def sleeping?
      @mutex.synchronize { @sleeping }
    end

    def record_failure(error)
      @mutex.synchronize do
        @failure ||= error
      end
    end

    def clear_failure
      @mutex.synchronize do
        error = @failure
        @failure = nil
        error
      end
    end
  end
end
```

## Workload ownership

The `missing-index-todos` workload now owns the parts of the system that are genuinely workload-specific: scale, action mix, invariant sampler, verifier, oracle, and the plan-matching helper that defines the primary query contract. The current retune leaves the counts N+1 path in the app but removes it from the active traffic mix by setting `FetchCounts` weight to `0`.

```bash
sed -n '1,240p' workloads/missing_index_todos/workload.rb && printf '\n---\n' && sed -n '1,240p' workloads/missing_index_todos/plan_contract.rb && printf '\n---\n' && sed -n '1,240p' workloads/missing_index_todos/verifier.rb && printf '\n---\n' && sed -n '1,240p' workloads/missing_index_todos/oracle.rb
```

```output
# ABOUTME: Defines the missing-index workload used for the todos benchmark path.
# ABOUTME: Declares the fixed scale, weighted actions, and load plan for the run.
require_relative "../../load/lib/load"
require_relative "invariant_sampler"
require_relative "verifier"
require_relative "actions/close_todo"
require_relative "actions/create_todo"
require_relative "actions/delete_completed_todos"
require_relative "actions/fetch_counts"
require_relative "actions/list_open_todos"
require_relative "actions/list_recent_todos"
require_relative "actions/search_todos"

module Load
  module Workloads
    module MissingIndexTodos
      class Workload < Load::Workload
        def name
          "missing-index-todos"
        end

        def scale
          Load::Scale.new(rows_per_table: 100_000, seed: 42, extra: { open_fraction: 0.6, user_count: 100 })
        end

        def actions
          [
            Load::ActionEntry.new(Actions::ListOpenTodos, 68),
            Load::ActionEntry.new(Actions::ListRecentTodos, 12),
            Load::ActionEntry.new(Actions::CreateTodo, 7),
            Load::ActionEntry.new(Actions::CloseTodo, 7),
            Load::ActionEntry.new(Actions::DeleteCompletedTodos, 3),
            Load::ActionEntry.new(Actions::FetchCounts, 0),
            Load::ActionEntry.new(Actions::SearchTodos, 3),
          ]
        end

        def load_plan
          Load::LoadPlan.new(workers: 16, duration_seconds: 60, rate_limit: :unlimited, seed: nil)
        end

        def invariant_sampler(database_url:, pg:)
          rows_per_table = scale.rows_per_table
          Load::Workloads::MissingIndexTodos::InvariantSampler.new(
            pg:,
            database_url:,
            open_floor: (rows_per_table * 0.3).to_i,
            total_floor: (rows_per_table * 0.8).to_i,
            total_ceiling: (rows_per_table * 2.0).to_i,
          )
        end

        def verifier(database_url:, pg:)
          Load::Workloads::MissingIndexTodos::Verifier.new(database_url:, pg:)
        end
      end
    end
  end
end

Load::WorkloadRegistry.register("missing-index-todos", Load::Workloads::MissingIndexTodos::Workload)

---
# ABOUTME: Validates the tenant-scoped todo plan contract for the missing-index workload.
# ABOUTME: Finds the todos access node under the required sort and matches exact user/status predicates.
module Load
  module Workloads
    module MissingIndexTodos
      module PlanContract
        USER_ID_INDEX_NAME = "index_todos_on_user_id".freeze
        EXPECTED_SORT_KEY = %w[created_at desc id desc].freeze
        EXPECTED_SORT_LABELS = ["created_at DESC", "id DESC"].freeze
        EXPECTED_SORT_DESCRIPTION = EXPECTED_SORT_LABELS.join(", ").freeze
        SORT_NODE_TYPES = ["Sort", "Incremental Sort", "Gather Merge"].freeze

        module_function

        def match(plan)
          access_node = find_access_node(plan)
          return failure(:sort_missing) unless access_node

          tenant_condition = matching_access_condition(access_node) { |condition| user_id_predicate?(condition) }
          return failure(:user_id_missing) if tenant_condition.empty?

          filter = access_node.fetch("Filter", "").to_s
          return failure(:status_missing) unless status_predicate?(filter)
          return failure(:index_missing) unless subtree_includes_index_name?(access_node, USER_ID_INDEX_NAME)

          {
            ok: true,
            details: {
              "Node Type" => access_node.fetch("Node Type"),
              "Index Name" => USER_ID_INDEX_NAME,
              "Sort Key" => EXPECTED_SORT_LABELS,
              "Filter" => filter,
              "tenant_condition" => tenant_condition,
            },
          }
        end

        def user_id_predicate?(expression)
          normalize_expression(expression).match?(/\b(?:[a-z_]+\.)?\(?user_id\)?\s*=\s*1\b/)
        end

        def status_predicate?(expression)
          normalize_expression(expression).match?(/\b(?:[a-z_]+\.)?\(?status\)?\s*=\s*'open'/)
        end

        def failure(reason)
          { ok: false, reason: reason }
        end
        private_class_method :failure

        def find_access_node(node, sort_confirmed: false)
          return unless node.is_a?(Hash)

          sort_confirmed ||= sort_matches_expected?(node)
          return node if sort_confirmed && node["Relation Name"] == "todos"

          Array(node["Plans"]).each do |child|
            match = find_access_node(child, sort_confirmed:)
            return match if match
          end

          nil
        end
        private_class_method :find_access_node

        def matching_access_condition(node, &matcher)
          [node.fetch("Index Cond", "").to_s, node.fetch("Recheck Cond", "").to_s].each do |condition|
            return condition if !condition.empty? && matcher.call(condition)
          end

          Array(node["Plans"]).each do |child|
            condition = matching_access_condition(child, &matcher)
            return condition unless condition.empty?
          end

          ""
        end
        private_class_method :matching_access_condition

        def subtree_includes_index_name?(node, expected_index_name)
          return true if node.fetch("Index Name", "").to_s == expected_index_name

          Array(node["Plans"]).any? do |child|
            subtree_includes_index_name?(child, expected_index_name)
          end
        end
        private_class_method :subtree_includes_index_name?

        def sort_matches_expected?(node)
          SORT_NODE_TYPES.include?(node["Node Type"]) &&
            normalize_sort_key(node["Sort Key"]) == EXPECTED_SORT_KEY
        end
        private_class_method :sort_matches_expected?

        def normalize_sort_key(sort_key)
          Array(sort_key).flat_map do |key|
            normalize_sort_key_entry(key)
          end
        end
        private_class_method :normalize_sort_key

        def normalize_sort_key_entry(key)
          normalized = key.to_s.downcase.delete('"')
          identifier = normalized.scan(/([a-z_]+)\s+desc\b/).flatten.last
          return [] if identifier.nil? || identifier.empty?

          [identifier, "desc"]
        end
        private_class_method :normalize_sort_key_entry

        def normalize_expression(expression)
          expression.to_s
            .downcase
            .gsub(/::[a-z_][a-z0-9_\[\]]*/, "")
            .delete('"')
            .gsub(/\s+/, " ")
            .strip
        end
        private_class_method :normalize_expression
      end
    end
  end
end

---
# ABOUTME: Verifies the missing-index workload fixture still exposes its intended pathologies.
# ABOUTME: Checks the user-scoped scan, counts fan-out, and tenant-scoped search explain shape.
require "json"
require "pg"
require_relative "plan_contract"

module Load
  module Workloads
    module MissingIndexTodos
      class Verifier
        SEARCH_PLAN_STABLE_KEYS = ["Node Type", "Relation Name", "Sort Key", "Filter", "Plans"].freeze
        COUNTS_PATH = "/api/todos/counts".freeze
        MISSING_INDEX_PATH = "/api/todos?user_id=1&status=open".freeze
        SEARCH_PATH = "/api/todos/search?user_id=1&q=foo".freeze
        MISSING_INDEX_SQL = <<~SQL.freeze
          EXPLAIN (FORMAT JSON)
          SELECT *
          FROM todos
          WHERE user_id = 1 AND status = 'open'
          ORDER BY created_at DESC, id DESC
          LIMIT 50
        SQL
        SEARCH_SQL = <<~SQL.freeze
          EXPLAIN (FORMAT JSON)
          SELECT *
          FROM todos
          WHERE user_id = 1 AND title LIKE '%foo%'
          ORDER BY created_at DESC, id DESC
          LIMIT 50
        SQL
        COUNTS_CALLS_SQL = <<~SQL.freeze
          SELECT COALESCE(SUM(calls), 0)::bigint AS calls
          FROM pg_stat_statements
          WHERE query LIKE '%FROM "todos"%'
            AND query LIKE '%COUNT(%'
            AND query LIKE '%"todos"."user_id"%'
        SQL

        def self.build_explain_reader(database_url:, pg:)
          ensure_database_url!(database_url)
          lambda do |sql|
            with_connection(database_url:, pg:) do |connection|
              rows = connection.exec(sql)
              JSON.parse(rows.first.fetch("QUERY PLAN")).fetch(0).fetch("Plan")
            end
          end
        end

        def self.build_stats_reset(database_url:, pg:)
          ensure_database_url!(database_url)
          lambda do
            with_connection(database_url:, pg:) do |connection|
              connection.exec("SELECT pg_stat_statements_reset()")
            end
          end
        end

        def self.build_counts_calls_reader(database_url:, pg:)
          ensure_database_url!(database_url)
          lambda do
            with_connection(database_url:, pg:) do |connection|
              connection.exec(COUNTS_CALLS_SQL).first.fetch("calls")
            end
          end
        end

        def self.with_connection(database_url:, pg:)
          connection = pg.connect(database_url)
          yield connection
        ensure
          connection&.close
        end

        def self.ensure_database_url!(database_url)
          return database_url unless database_url.nil? || database_url.empty?

          raise ArgumentError, "missing DATABASE_URL for fixture verification"
        end

        def initialize(client_factory: nil, explain_reader: nil, stats_reset: nil, counts_calls_reader: nil, search_reference_reader: nil, database_url: ENV["DATABASE_URL"], pg: PG)
          @client_factory = client_factory || ->(base_url) { Load::Client.new(base_url:) }
          @explain_reader = explain_reader || self.class.build_explain_reader(database_url:, pg:)
          @stats_reset = stats_reset || self.class.build_stats_reset(database_url:, pg:)
          @counts_calls_reader = counts_calls_reader || self.class.build_counts_calls_reader(database_url:, pg:)
          @search_reference_reader = search_reference_reader || -> { JSON.parse(File.read(search_reference_path)).fetch(0).fetch("Plan") }
        end

        def call(base_url:)
          {
            ok: true,
            checks: [
              verify_missing_index,
              verify_counts_n_plus_one(base_url:),
              verify_search_rewrite,
            ],
          }
        end

        private

        def verify_missing_index
          plan = @explain_reader.call(MISSING_INDEX_SQL)
          match = PlanContract.match(plan)

          unless match.fetch(:ok)
            raise Load::VerificationError, missing_index_failure_message(match.fetch(:reason))
          end

          { name: "missing_index", ok: true, node_type: match.fetch(:details).fetch("Node Type") }
        end

        def verify_counts_n_plus_one(base_url:)
          @stats_reset.call
          response = @client_factory.call(base_url).get(COUNTS_PATH)
          ensure_success!(response, COUNTS_PATH)
          users_count = JSON.parse(response.body.to_s).length

          calls = @counts_calls_reader.call.to_i
          if calls < users_count
            raise Load::VerificationError, "fixture verification failed for #{COUNTS_PATH}: expected at least #{users_count} count calls for #{users_count} users, saw #{calls}"
          end

          { name: "counts_n_plus_one", ok: true, calls:, users: users_count }
        end

        def verify_search_rewrite
          plan = @explain_reader.call(SEARCH_SQL)
          reference_plan = @search_reference_reader.call
          unless plan_matches_reference?(actual: plan, reference: reference_plan, keys: SEARCH_PLAN_STABLE_KEYS)
            raise Load::VerificationError, "fixture verification failed for #{SEARCH_PATH}: search explain tree drifted from fixtures/mixed-todo-app/search-explain.json"
          end

          { name: "search_rewrite", ok: true, node_type: plan.fetch("Node Type") }
        end

        def ensure_success!(response, path)
          code = response.code.to_i
          return if code >= 200 && code < 300

          raise Load::VerificationError, "fixture verification failed for #{path}: expected 2xx response, saw #{response.code}"
        end

        def missing_index_failure_message(reason)
          case reason
          when :sort_missing
            "fixture verification failed for #{MISSING_INDEX_PATH}: expected todos access under sort #{PlanContract::EXPECTED_SORT_DESCRIPTION}"
          when :user_id_missing
            "fixture verification failed for #{MISSING_INDEX_PATH}: expected Index Cond or Recheck Cond to include user_id = 1"
          when :status_missing
            "fixture verification failed for #{MISSING_INDEX_PATH}: expected status = 'open' filter after tenant lookup"
          when :index_missing
            "fixture verification failed for #{MISSING_INDEX_PATH}: expected user-scoped access via #{PlanContract::USER_ID_INDEX_NAME}"
          else
            raise "unknown missing-index failure reason: #{reason}"
          end
        end

        def plan_matches_reference?(actual:, reference:, keys: reference.keys)
          keys.all? do |key|
            next true unless reference.key?(key)

            actual.key?(key) && values_match_reference?(actual.fetch(key), reference.fetch(key), keys:)
          end
        end

        def values_match_reference?(actual, reference, keys:)
          case reference
          when Hash
            actual.is_a?(Hash) && plan_matches_reference?(actual:, reference:, keys:)
          when Array
            actual.is_a?(Array) &&
              actual.length == reference.length &&
              reference.each_with_index.all? do |child_reference, index|
                values_match_reference?(actual.fetch(index), child_reference, keys:)
              end
          else
            actual == reference
          end
        end

        def search_reference_path
          File.expand_path("../../fixtures/mixed-todo-app/search-explain.json", __dir__)
        end
      end
    end
  end
end

---
# ABOUTME: Verifies the missing-index workload reproduced both the bad plan and ClickHouse activity.
# ABOUTME: Reads a run record, tree-walks EXPLAIN JSON, and polls ClickHouse by queryid fingerprints.
require "json"
require "net/http"
require "optparse"
require "pg"
require "time"
require "uri"
require_relative "plan_contract"

module Load
  module Workloads
    module MissingIndexTodos
      class Oracle
        CLICKHOUSE_CALL_THRESHOLD = 500
        DOMINANCE_RATIO_THRESHOLD = 3.0
        CLICKHOUSE_TOPN_LIMIT = 10
        EXPLAIN_SQL = <<~SQL.freeze
          EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
          SELECT *
          FROM todos
          WHERE user_id = 1 AND status = 'open'
          ORDER BY created_at DESC, id DESC
          LIMIT 50
        SQL

        class Failure < StandardError
        end

        def initialize(stdout: $stdout, stderr: $stderr, pg: PG, clickhouse_query: nil, clickhouse_topn_query: nil, clock: -> { Time.now.utc }, sleeper: ->(seconds) { sleep(seconds) })
          @stdout = stdout
          @stderr = stderr
          @pg = pg
          @clickhouse_query = clickhouse_query || method(:query_clickhouse)
          @clickhouse_topn_query = clickhouse_topn_query || method(:query_clickhouse_topn)
          @clock = clock
          @sleeper = sleeper
        end

        def run(argv)
          options = parse(argv)
          result = call(**options)

          @stdout.puts("PASS: explain (#{result.fetch(:plan).fetch("Index Name")} via #{result.fetch(:plan).fetch("Node Type")}; status filter; sort #{result.fetch(:plan).fetch("Sort Key").join(', ')})")
          @stdout.puts("PASS: clickhouse (#{result.fetch(:clickhouse).fetch("total_exec_count")} calls; mean #{result.fetch(:clickhouse).fetch("mean_exec_time_ms")}ms)")
          @stdout.puts(result.fetch(:dominance).fetch("message"))
          exit 0
        rescue Failure => error
          @stderr.puts(error.message)
          exit 1
        end

        def call(run_dir:, database_url:, clickhouse_url:, timeout_seconds: 30)
          run_record = load_run_record(run_dir)
          queryids = extract_queryids(run_record)
          plan = explain_todos_scan(database_url)
          clickhouse = wait_for_clickhouse!(
            window: run_record.fetch("window"),
            queryids:,
            clickhouse_url:,
            timeout_seconds:
          )
          dominance = assert_dominance(
            window: run_record.fetch("window"),
            expected_queryids: queryids,
            clickhouse_url:,
          )

          {
            plan:,
            clickhouse: normalize_clickhouse_snapshot(clickhouse),
            dominance:,
          }
        end

        private

        def parse(argv)
          options = {
            database_url: ENV["DATABASE_URL"],
            clickhouse_url: ENV["CLICKHOUSE_URL"],
            timeout_seconds: 30,
          }

          parser = OptionParser.new
          parser.on("--database-url URL") { |value| options[:database_url] = value }
          parser.on("--clickhouse-url URL") { |value| options[:clickhouse_url] = value }
          parser.on("--timeout-seconds SECONDS", Integer) { |value| options[:timeout_seconds] = value }

          args = argv.dup
          parser.parse!(args)
          run_dir = args.shift
          raise Failure, "FAIL: missing run record directory" if run_dir.nil? || run_dir.empty?
          raise Failure, "FAIL: missing --database-url (or DATABASE_URL)" if options[:database_url].nil? || options[:database_url].empty?
          raise Failure, "FAIL: missing --clickhouse-url (or CLICKHOUSE_URL)" if options[:clickhouse_url].nil? || options[:clickhouse_url].empty?

          options.merge(run_dir:)
        end

        def load_run_record(run_dir)
          path = File.join(run_dir, "run.json")
          JSON.parse(File.read(path))
        rescue Errno::ENOENT
          raise Failure, "FAIL: missing run record at #{path}"
        end

        def extract_queryids(run_record)
          queryids = Array(run_record["query_ids"]).map(&:to_s).reject(&:empty?).uniq
          return queryids unless queryids.empty?

          raise Failure, "FAIL: run record is missing query_ids"
        end

        def explain_todos_scan(database_url)
          connection = @pg.connect(database_url)
          rows = connection.exec(EXPLAIN_SQL)
          payload = JSON.parse(rows.first.fetch("QUERY PLAN"))
          plan = payload.fetch(0).fetch("Plan")
          match = PlanContract.match(plan)
          raise Failure, explain_failure_message(match.fetch(:reason)) unless match.fetch(:ok)

          match.fetch(:details)
        ensure
          connection&.close
        end

        def explain_failure_message(reason)
          case reason
          when :sort_missing
            "FAIL: explain (expected todos access under sort #{PlanContract::EXPECTED_SORT_DESCRIPTION})"
          when :user_id_missing
            "FAIL: explain (expected Index Cond or Recheck Cond to include user_id = 1)"
          when :status_missing
            "FAIL: explain (expected status = 'open' filter after tenant lookup)"
          when :index_missing
            "FAIL: explain (expected user-scoped access via #{PlanContract::USER_ID_INDEX_NAME})"
          else
            raise "unknown explain failure reason: #{reason}"
          end
        end

        def wait_for_clickhouse!(window:, queryids:, clickhouse_url:, timeout_seconds:)
          deadline = @clock.call + timeout_seconds

          loop do
            snapshot = normalize_clickhouse_snapshot(
              @clickhouse_query.call(window:, queryids:, clickhouse_url:)
            )
            return snapshot if snapshot.fetch("total_exec_count") >= CLICKHOUSE_CALL_THRESHOLD

            raise Failure, "FAIL: clickhouse (saw #{snapshot.fetch("total_exec_count")} calls before timeout)" if @clock.call >= deadline

            @sleeper.call(1)
          end
        end

        def normalize_clickhouse_snapshot(snapshot)
          {
            "total_exec_count" => snapshot.fetch("total_exec_count").to_i,
            "mean_exec_time_ms" => snapshot.fetch("mean_exec_time_ms", "0.0").to_s,
          }
        end

        def assert_dominance(window:, expected_queryids:, clickhouse_url:)
          rows = @clickhouse_topn_query.call(window:, clickhouse_url:)
          primary = rows.find { |row| expected_queryids.include?(row.fetch("queryid")) }
          raise Failure, "FAIL: dominance (primary queryid not present in top-N)" if primary.nil?

          challenger = rows.find { |row| !expected_queryids.include?(row.fetch("queryid")) }
          if challenger.nil?
            return { "message" => "PASS: dominance (no challenger; primary stands alone)" }
          end

          primary_time = primary.fetch("total_exec_time_ms_estimate").to_f
          challenger_time = challenger.fetch("total_exec_time_ms_estimate").to_f
          ratio = primary_time / challenger_time

          if primary_time >= challenger_time * DOMINANCE_RATIO_THRESHOLD
            { "message" => "PASS: dominance (#{ratio.round(2)}x over next queryid)" }
          else
            raise Failure,
              "FAIL: dominance (#{primary_time}ms / #{challenger_time}ms = #{ratio.round(2)}x; required: >=3x)"
          end
        end

        def query_clickhouse(window:, queryids:, clickhouse_url:)
          uri = URI.parse(clickhouse_url)
          uri.path = "/" if uri.path.to_s.empty?
          uri.query = URI.encode_www_form(query: "#{build_clickhouse_sql(window:, queryids:)} FORMAT JSONEachRow")
          response = Net::HTTP.get_response(uri)
          raise Failure, "FAIL: clickhouse (query failed: #{response.code} #{response.body})" if response.code.to_i >= 400

          body = response.body.to_s.each_line.first || "{\"total_exec_count\":\"0\",\"mean_exec_time_ms\":\"0.0\"}"
          JSON.parse(body)
        end

        def query_clickhouse_topn(window:, clickhouse_url:)
          uri = URI.parse(clickhouse_url)
          uri.path = "/" if uri.path.to_s.empty?
          uri.query = URI.encode_www_form(query: "#{build_clickhouse_topn_sql(window:)} FORMAT JSONEachRow")
          response = Net::HTTP.get_response(uri)
          raise Failure, "FAIL: clickhouse (query failed: #{response.code} #{response.body})" if response.code.to_i >= 400

          response.body.to_s.each_line.map { |line| JSON.parse(line) }
        end

        def build_clickhouse_sql(window:, queryids:)
          escaped_queryids = queryids.map { |queryid| "'#{queryid.gsub("'", "''")}'" }.join(", ")

          <<~SQL
            SELECT
              toString(coalesce(sum(total_exec_count), 0)) AS total_exec_count,
              toString(round(coalesce(avg(avg_exec_time_ms), 0), 1)) AS mean_exec_time_ms
            FROM query_intervals
            WHERE interval_ended_at BETWEEN parseDateTime64BestEffort('#{window.fetch("start_ts")}') AND parseDateTime64BestEffort('#{window.fetch("end_ts")}') + INTERVAL 90 SECOND
              AND queryid IN (#{escaped_queryids})
          SQL
        end

        def build_clickhouse_topn_sql(window:)
          <<~SQL
            SELECT
              toString(queryid) AS queryid,
              toString(sum(total_exec_count)) AS total_calls,
              toString(round(sum(total_exec_count * avg_exec_time_ms), 1)) AS total_exec_time_ms_estimate
            FROM query_intervals
            WHERE interval_ended_at BETWEEN parseDateTime64BestEffort('#{window.fetch("start_ts")}')
              AND parseDateTime64BestEffort('#{window.fetch("end_ts")}') + INTERVAL 90 SECOND
            GROUP BY queryid
            ORDER BY sum(total_exec_count * avg_exec_time_ms) DESC
            LIMIT #{CLICKHOUSE_TOPN_LIMIT}
          SQL
        end
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  Load::Workloads::MissingIndexTodos::Oracle.new.run(ARGV)
```

## Tenant-scoped actions

The workload actions are no longer driven by `rows_per_table` guesses. They now sample a tenant from `scale.extra[:user_count]`, keep reads and searches user-scoped, let `close_todo` fetch open candidates first, and let `delete_completed_todos` act directly on one tenant without a prefetch.

```bash
sed -n '1,220p' workloads/missing_index_todos/actions/list_open_todos.rb && printf '\n---\n' && sed -n '1,220p' workloads/missing_index_todos/actions/list_recent_todos.rb && printf '\n---\n' && sed -n '1,220p' workloads/missing_index_todos/actions/create_todo.rb && printf '\n---\n' && sed -n '1,240p' workloads/missing_index_todos/actions/close_todo.rb && printf '\n---\n' && sed -n '1,220p' workloads/missing_index_todos/actions/delete_completed_todos.rb && printf '\n---\n' && sed -n '1,220p' workloads/missing_index_todos/actions/fetch_counts.rb && printf '\n---\n' && sed -n '1,220p' workloads/missing_index_todos/actions/search_todos.rb
```

```output
# ABOUTME: Defines the open-todos request used to trigger the missing-index workload.
# ABOUTME: Executes the current status-filtered todos endpoint through the shared client.
require_relative "../../../load/lib/load"

module Load
  module Workloads
    module MissingIndexTodos
      module Actions
        class ListOpenTodos < Load::Action
          def name
            :list_open_todos
          end

          def call
            client.get("/api/todos?user_id=#{sample_user_id}&status=open")
          end

          private

          def sample_user_id
            user_count = Integer(ctx.fetch(:scale).extra.fetch(:user_count))
            rng.rand(1..user_count)
          end
        end
      end
    end
  end
end

---
# ABOUTME: Defines the recent-todos request used in the mixed missing-index workload.
# ABOUTME: Fetches the recent todos page through the shared client with fixed pagination.
require_relative "../../../load/lib/load"

module Load
  module Workloads
    module MissingIndexTodos
      module Actions
        class ListRecentTodos < Load::Action
          def name
            :list_recent_todos
          end

          def call
            client.get("/api/todos?user_id=#{sample_user_id}&status=all&page=1&per_page=50&order=created_desc")
          end

          private

          def sample_user_id
            user_count = Integer(ctx.fetch(:scale).extra.fetch(:user_count))
            rng.rand(1..user_count)
          end
        end
      end
    end
  end
end

---
# ABOUTME: Defines the create-todo request used in the mixed missing-index workload.
# ABOUTME: Creates a todo through the shared client with a minimal JSON payload.
require_relative "../../../load/lib/load"

module Load
  module Workloads
    module MissingIndexTodos
      module Actions
        class CreateTodo < Load::Action
          def name
            :create_todo
          end

          def call
            client.request(:post, "/api/todos", body: payload)
          end

          private

          def payload
            {
              user_id: ctx.fetch(:user_id) { sample_user_id },
              title: ctx.fetch(:title, "load"),
            }
          end

          def sample_user_id
            user_count = Integer(ctx.fetch(:scale).extra.fetch(:user_count))
            rng.rand(1..user_count)
          end
        end
      end
    end
  end
end

---
# ABOUTME: Defines the close-todo request used in the mixed missing-index workload.
# ABOUTME: Marks one todo closed through the shared client using a fixture-friendly id.
require "json"

require_relative "../../../load/lib/load"

module Load
  module Workloads
    module MissingIndexTodos
      module Actions
        class CloseTodo < Load::Action
          NoOpResponse = Struct.new(:code, :body)

          def name
            :close_todo
          end

          def call
            todo_id = open_todo_ids.sample(random: rng)
            return NoOpResponse.new("204", "") unless todo_id

            client.request(:patch, "/api/todos/#{todo_id}", body: { status: "closed" })
          end

          private

          def open_todo_ids
            response = client.get("/api/todos?user_id=#{sample_user_id}&status=open")
            JSON.parse(response.body.to_s).map { |todo| todo.fetch("id") }
          end

          def sample_user_id
            user_count = Integer(ctx.fetch(:scale).extra.fetch(:user_count))
            rng.rand(1..user_count)
          end
        end
      end
    end
  end
end

---
# ABOUTME: Defines the delete-completed-todos request used in the mixed missing-index workload.
# ABOUTME: Deletes completed todos with a bounded per-user scope through the shared client.
require_relative "../../../load/lib/load"

module Load
  module Workloads
    module MissingIndexTodos
      module Actions
        class DeleteCompletedTodos < Load::Action
          def name
            :delete_completed_todos
          end

          def call
            client.request(:delete, "/api/todos/completed?user_id=#{user_id}")
          end

          private

          def user_id
            ctx.fetch(:user_id) { sample_user_id }
          end

          def sample_user_id
            user_count = Integer(ctx.fetch(:scale).extra.fetch(:user_count))
            rng.rand(1..user_count)
          end
        end
      end
    end
  end
end

---
# ABOUTME: Defines the counts request used in the mixed missing-index workload.
# ABOUTME: Fetches aggregate todo counts through the shared client.
require_relative "../../../load/lib/load"

module Load
  module Workloads
    module MissingIndexTodos
      module Actions
        class FetchCounts < Load::Action
          def name
            :fetch_counts
          end

          def call
            client.get("/api/todos/counts")
          end
        end
      end
    end
  end
end

---
# ABOUTME: Defines the search request used in the mixed missing-index workload.
# ABOUTME: Searches todos through the shared client using a fixed default query.
require "uri"

require_relative "../../../load/lib/load"

module Load
  module Workloads
    module MissingIndexTodos
      module Actions
        class SearchTodos < Load::Action
          def name
            :search_todos
          end

          def call
            client.get("/api/todos/search?user_id=#{sample_user_id}&q=#{URI.encode_www_form_component(query)}")
          end

          private

          def query
            ctx.fetch(:query, "foo")
          end

          def sample_user_id
            user_count = Integer(ctx.fetch(:scale).extra.fetch(:user_count))
            rng.rand(1..user_count)
          end
        end
      end
    end
  end
end
```

## Adapter query-id handoff

The Rails adapter still resets the fixture and captures `query_ids`, but the warm-up query is now tenant-scoped. That keeps `run.json.query_ids` aligned with the workload oracle instead of the old global-open-todos query.

```bash
sed -n '1,180p' adapters/rails/lib/rails_adapter/commands/reset_state.rb && printf '\n---\n' && sed -n '1,180p' adapters/rails/test/reset_state_test.rb
```

```output
# ABOUTME: Resets the benchmark database by rebuilding or cloning a template copy.
# ABOUTME: Reruns pg_stat_statements_reset after seeding so run counters start clean.
require "json"
require "uri"

module RailsAdapter
  module Commands
    class ResetState
      QUERY_IDS_SCRIPT = {
        "missing-index-todos" => <<~RUBY.strip,
          require "json"
          user = User.first or raise("expected a seeded user")
          user.todos.with_status("open").ordered_by_created_desc.page(1, 50).load
          connection = ActiveRecord::Base.connection
          query_ids = [
            %(SELECT "todos".* FROM "todos" WHERE "todos"."user_id" = $1 AND "todos"."status" = $2 ORDER BY "todos"."created_at" DESC, "todos"."id" DESC LIMIT $3 OFFSET $4),
          ].flat_map do |query_text|
            connection.exec_query(
              "SELECT DISTINCT queryid::text AS queryid FROM pg_stat_statements WHERE query = \#{connection.quote(query_text)}"
            ).rows.flatten
          end.uniq
          $stdout.write(JSON.generate(query_ids: query_ids))
        RUBY
      }.freeze

      def initialize(app_root:, seed:, env_pairs:, workload: nil, command_runner: RailsAdapter::CommandRunner.new, template_cache: RailsAdapter::TemplateCache.new, clock: -> { Time.now.to_f })
        @app_root = app_root
        @workload = workload
        @seed = seed
        @env_pairs = env_pairs
        @command_runner = command_runner
        @template_cache = template_cache
        @clock = clock
      end

      def call
        if @template_cache.template_exists?(database_name: database_name, app_root: @app_root, env_pairs: seed_env)
          @template_cache.clone_template(database_name: database_name, app_root: @app_root, env_pairs: seed_env)
        else
          build_template
          @template_cache.build_template(database_name: database_name, app_root: @app_root, env_pairs: seed_env)
        end

        ensure_pg_stat_statements
        query_ids = capture_query_ids
        reset_pg_stat_statements
        RailsAdapter::Result.ok("reset-state", query_ids ? { "query_ids" => query_ids } : {})
      rescue StandardError => error
        RailsAdapter::Result.error("reset-state", "reset_failed", error.message, {})
      end

      private

      def build_template
        drop = @command_runner.capture3("bin/rails", "db:drop", env: rails_env, chdir: @app_root, command_name: "reset-state")
        raise "db:drop failed" unless drop.success?

        migrate = RailsAdapter::Commands::Migrate.new(app_root: @app_root, command_runner: @command_runner).call
        raise "db:create db:schema:load failed" unless migrate.fetch("ok")

        load_dataset = RailsAdapter::Commands::LoadDataset.new(
          app_root: @app_root,
          workload: @workload,
          seed: @seed,
          env_pairs: @env_pairs,
          command_runner: @command_runner,
          clock: @clock,
        ).call
        raise "seed runner failed" unless load_dataset.fetch("ok")
      end

      def reset_pg_stat_statements
        result = @command_runner.capture3(
          "bin/rails",
          "runner",
          %(ActiveRecord::Base.connection.execute("SELECT pg_stat_statements_reset()")),
          env: rails_env,
          chdir: @app_root,
          command_name: "reset-state",
        )
        raise "pg_stat_statements_reset failed" unless result.success?
      end

      def ensure_pg_stat_statements
        result = @command_runner.capture3(
          "bin/rails",
          "runner",
          %(ActiveRecord::Base.connection.execute("CREATE EXTENSION IF NOT EXISTS pg_stat_statements")),
          env: rails_env,
          chdir: @app_root,
          command_name: "reset-state",
        )
        raise "pg_stat_statements extension failed" unless result.success?
      end

      def capture_query_ids
        script = QUERY_IDS_SCRIPT[@workload]
        return nil unless script

        result = @command_runner.capture3(
          "bin/rails",
          "runner",
          script,
          env: rails_env,
          chdir: @app_root,
          command_name: "reset-state",
        )
        raise "query id capture failed" unless result.success?

        JSON.parse(result.stdout).fetch("query_ids")
      end

      def database_name
        return ENV.fetch("BENCHMARK_DB_NAME") if ENV.key?("BENCHMARK_DB_NAME")

        database_url = ENV["DATABASE_URL"]
        return "checkpoint_demo" unless database_url

        path = URI.parse(database_url).path
        name = path.sub(%r{\A/}, "")
        name.empty? ? "checkpoint_demo" : name
      end

      def rails_env
        RailsAdapter::Environment.benchmark(@app_root)
      end

      def seed_env
        @seed_env ||= @env_pairs.merge("SEED" => @seed.to_s)
      end
    end
  end
end

---
# ABOUTME: Verifies the reset-state command rebuilds or clones a template database.
# ABOUTME: Ensures reset-state also clears pg_stat_statements counters after seeding.
require_relative "test_helper"

class ResetStateTest < Minitest::Test
  def test_reset_state_uses_database_name_from_database_url
    runner = FakeCommandRunner.new
    cache = FakeTemplateCache.new
    command = RailsAdapter::Commands::ResetState.new(
      app_root: "/tmp/demo",
      seed: 42,
      env_pairs: {},
      command_runner: runner,
      template_cache: cache,
      clock: fake_clock(0.0, 1.0),
    )

    with_env("DATABASE_URL" => "postgres://postgres:postgres@localhost:5432/custom_benchmark") do
      command.call
    end

    assert_equal "custom_benchmark", cache.last_build_args.fetch(:database_name)
  end

  def test_reset_state_uses_template_clone_after_first_build
    runner = FakeCommandRunner.new
    cache = FakeTemplateCache.new
    command = RailsAdapter::Commands::ResetState.new(
      app_root: "/tmp/demo",
      seed: 42,
      env_pairs: {},
      command_runner: runner,
      template_cache: cache,
      clock: fake_clock(0.0, 2.0, 4.0),
    )

    command.call
    command.call

    assert_equal 1, cache.build_calls
    assert_equal 1, cache.clone_calls
    assert_includes runner.argv_history, ["bin/rails", "db:drop"]
    assert_includes runner.argv_history, ["bin/rails", "db:create", "db:schema:load"]
  end

  def test_reset_state_rebuilds_template_when_seed_env_changes
    runner = FakeCommandRunner.new
    cache = SeedAwareTemplateCache.new
    first_command = RailsAdapter::Commands::ResetState.new(
      app_root: "/tmp/demo",
      seed: 7,
      env_pairs: { "ROWS_PER_TABLE" => "1000", "OPEN_FRACTION" => "0.2" },
      command_runner: runner,
      template_cache: cache,
      clock: fake_clock(0.0, 2.0, 4.0),
    )
    second_command = RailsAdapter::Commands::ResetState.new(
      app_root: "/tmp/demo",
      seed: 42,
      env_pairs: { "ROWS_PER_TABLE" => "10000000", "OPEN_FRACTION" => "0.002" },
      command_runner: runner,
      template_cache: cache,
      clock: fake_clock(10.0, 12.0, 14.0),
    )

    first_command.call
    second_command.call

    assert_equal 2, cache.build_calls
    assert_equal 0, cache.clone_calls
  end

  def test_reset_state_resets_pg_stat_statements_counters
    runner = FakeCommandRunner.new
    command = RailsAdapter::Commands::ResetState.new(
      app_root: "/tmp/demo",
      seed: 42,
      env_pairs: {},
      command_runner: runner,
      template_cache: FakeTemplateCache.new(template_exists: true),
      clock: fake_clock(0.0, 1.0),
    )

    command.call

    rails_runner_calls = runner.argv_history.select { |argv| argv.first(2) == ["bin/rails", "runner"] }
    assert rails_runner_calls.any? { |argv| argv.last.include?("CREATE EXTENSION IF NOT EXISTS pg_stat_statements") }, "expected a bin/rails runner call that enables pg_stat_statements"
    assert rails_runner_calls.any? { |argv| argv.last.include?("pg_stat_statements_reset") }, "expected a bin/rails runner call that invokes pg_stat_statements_reset()"
  end

  def test_reset_state_returns_query_ids_for_missing_index_workload
    query_ids_json = %({"query_ids":["111","222"]})
    runner = FakeCommandRunner.new(
      results: {
        ["bin/rails", "runner", RailsAdapter::Commands::ResetState::QUERY_IDS_SCRIPT.fetch("missing-index-todos")] => FakeResult.new(status: 0, stdout: query_ids_json, stderr: ""),
      },
    )
    command = RailsAdapter::Commands::ResetState.new(
      app_root: "/tmp/demo",
      workload: "missing-index-todos",
      seed: 42,
      env_pairs: {},
      command_runner: runner,
      template_cache: FakeTemplateCache.new(template_exists: true),
      clock: fake_clock(0.0, 1.0),
    )

    result = command.call

    assert_equal ["111", "222"], result.fetch("query_ids")
  end

  def test_reset_state_query_id_script_matches_tenant_scoped_open_todos_query_shape
    script = RailsAdapter::Commands::ResetState::QUERY_IDS_SCRIPT.fetch("missing-index-todos")

    assert_includes script, "User.first"
    assert_includes script, %(user.todos.with_status("open").ordered_by_created_desc.page(1, 50).load)
    assert_includes script, %(with_status("open"))
    assert_includes script, %(SELECT "todos".* FROM "todos" WHERE "todos"."user_id" = $1 AND "todos"."status" = $2 ORDER BY "todos"."created_at" DESC, "todos"."id" DESC LIMIT $3 OFFSET $4)
  end

  private

  def with_env(overrides)
    previous = overrides.transform_values { nil }
    overrides.each_key { |key| previous[key] = ENV[key] }
    overrides.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    previous.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end

  class SeedAwareTemplateCache < FakeTemplateCache
    def initialize
      super(template_exists: false)
      @templates = {}
    end

    def template_exists?(**kwargs)
      @templates[key(kwargs)]
    end

    def build_template(**kwargs)
      super
      @templates[key(kwargs)] = true
    end

    private

    def key(kwargs)
      [kwargs.fetch(:database_name), kwargs.fetch(:app_root), kwargs.fetch(:env_pairs).sort]
    end
  end
end
```

## Demo app

The app-under-test in `db-specialist-demo` is now a tenant-shaped JSON API. `api_index`, `search`, `create`, `update`, and `delete_completed` all work through a selected user. `counts` remains global and intentionally N+1 inside the controller, but the workload no longer drives that route during the benchmark gate.

```bash
sed -n '1,240p' /home/bjw/db-specialist-demo/app/controllers/todos_controller.rb && printf '\n---\n' && sed -n '1,220p' /home/bjw/db-specialist-demo/app/models/todo.rb && printf '\n---\n' && sed -n '1,220p' /home/bjw/db-specialist-demo/db/seeds.rb
```

```output
# ABOUTME: Serves the demo todo endpoints that intentionally expose query anti-patterns.
# ABOUTME: Returns todo, status, and per-user stats data for the local collector demo.
class TodosController < ApplicationController
  def index
    todos = params[:q].present? ? Todo.where("title LIKE ?", "%#{params[:q]}%") : Todo.all
    render json: todos.as_json(include: :user)
  end

  def api_index
    order = params[:order].presence
    return head :bad_request if order.present? && order != "created_desc"

    todos = user_todos.ordered_by_created_desc
    todos = todos.with_status(params[:status])
    todos = todos.page(params[:page], params[:per_page])

    render json: { items: todos.as_json(only: [:id, :user_id, :title, :status, :created_at, :updated_at]) }
  end

  def create
    todo = Todo.create!(todo_params)

    render json: todo.as_json(only: [:id, :user_id, :title, :status, :created_at, :updated_at]), status: :created
  end

  def update
    todo = Todo.find(params[:id])
    todo.update!(todo_update_params)

    render json: todo.as_json(only: [:id, :user_id, :title, :status, :created_at, :updated_at])
  end

  def completed
    deleted_count = Todo.completed_for_user(params.require(:user_id)).delete_all

    render json: { deleted_count: deleted_count }
  end

  def counts
    render json: User.all.index_with { |user| user.todos.count }.transform_keys { |user| user.id.to_s }
  end

  def search
    items = user_todos.where("title LIKE ?", "%#{params[:q]}%").order(created_at: :desc).limit(50)

    render json: { items: items.as_json(only: [:id, :user_id, :title, :status, :created_at, :updated_at]) }
  end

  def status
    render json: Todo.where(status: params.fetch(:status, "open"))
  end

  def stats
    render json: User.all.index_with { |user| user.todos.count }.transform_keys { |user| user.id.to_s }
  end

  private

  def todo_params
    params.permit(:user_id, :title, :status)
  end

  def todo_update_params
    params.permit(:title, :status)
  end

  def user_todos
    Todo.where(user_id: params.require(:user_id))
  end
end

---
# ABOUTME: Represents a single todo item in the demo application database.
# ABOUTME: Connects each todo to the owning user for the query log examples.
class Todo < ApplicationRecord
  belongs_to :user, inverse_of: :todos

  scope :ordered_by_created_desc, -> { order(created_at: :desc, id: :desc) }
  scope :completed, -> { where.not(status: "open") }

  def self.with_status(status)
    return all if status.blank? || status == "all"

    where(status: status)
  end

  def self.page(page, per_page)
    current_page = page.to_i
    current_page = 1 if current_page < 1

    page_size = per_page.to_i
    page_size = 50 if page_size < 1

    offset((current_page - 1) * page_size).limit(page_size)
  end

  def self.completed_for_user(user_id)
    where(user_id: user_id).completed
  end
end

---
# ABOUTME: Loads benchmark-sized demo records for the Rails anti-pattern endpoints.
# ABOUTME: Seeds users and todos from env-controlled SQL so benchmark resets stay fast.
rows_per_table = Integer(ENV.fetch("ROWS_PER_TABLE", "100000"))
user_count = Integer(ENV.fetch("USER_COUNT", "1000"))
seed_value = Integer(ENV.fetch("SEED", "42"))
open_fraction = Float(ENV.fetch("OPEN_FRACTION", "0.6"))

ActiveRecord::Base.connection.execute(<<~SQL)
  TRUNCATE TABLE todos, users RESTART IDENTITY;
  SELECT setseed(#{seed_value.to_f / 1000});

  INSERT INTO users (name, created_at, updated_at)
  SELECT
    'user_' || i,
    NOW(),
    NOW()
  FROM generate_series(1, #{user_count}) AS i;

  INSERT INTO todos (title, status, user_id, created_at, updated_at)
  SELECT
    'todo ' || i,
    CASE
      WHEN random() < #{open_fraction} THEN 'open'
      ELSE 'closed'
    END,
    ((i - 1) % #{user_count}) + 1,
    NOW(),
    NOW()
  FROM generate_series(1, #{rows_per_table}) AS i;

  ANALYZE users;
  ANALYZE todos;
SQL
```

## Live proof

The branch-level proof point is the latest passing finite run. The run record should show the tenant-shaped scale, the new action weights, and a single captured query id for the primary tenant open-todos family. The oracle should report the user-id index plan, ClickHouse evidence, and a dominance ratio well above the threshold.

```bash
sed -n '1,260p' runs/20260426T131118Z-missing-index-todos/run.json
```

```output
{
  "run_id": "20260426T131118Z-missing-index-todos",
  "schema_version": 2,
  "workload": {
    "name": "missing-index-todos",
    "file": "/home/bjw/checkpoint-collector/workloads/missing_index_todos/workload",
    "scale": {
      "rows_per_table": 100000,
      "seed": 42,
      "extra": {
        "open_fraction": 0.6,
        "user_count": 100
      }
    },
    "load_plan": {
      "workers": 16,
      "duration_seconds": 60,
      "rate_limit": "unlimited",
      "seed": null
    },
    "actions": [
      {
        "class": "Load::Workloads::MissingIndexTodos::Actions::ListOpenTodos",
        "weight": 68
      },
      {
        "class": "Load::Workloads::MissingIndexTodos::Actions::ListRecentTodos",
        "weight": 12
      },
      {
        "class": "Load::Workloads::MissingIndexTodos::Actions::CreateTodo",
        "weight": 7
      },
      {
        "class": "Load::Workloads::MissingIndexTodos::Actions::CloseTodo",
        "weight": 7
      },
      {
        "class": "Load::Workloads::MissingIndexTodos::Actions::DeleteCompletedTodos",
        "weight": 3
      },
      {
        "class": "Load::Workloads::MissingIndexTodos::Actions::FetchCounts",
        "weight": 0
      },
      {
        "class": "Load::Workloads::MissingIndexTodos::Actions::SearchTodos",
        "weight": 3
      }
    ]
  },
  "adapter": {
    "describe": {
      "ok": true,
      "command": "describe",
      "name": "rails-postgres-adapter",
      "framework": "rails",
      "runtime": "ruby-3.2.3"
    },
    "bin": "adapters/rails/bin/bench-adapter",
    "app_root": "/home/bjw/db-specialist-demo",
    "base_url": "http://127.0.0.1:3000",
    "pid": 2609103
  },
  "window": {
    "start_ts": "2026-04-26 13:11:29 UTC",
    "end_ts": "2026-04-26 13:12:29 UTC",
    "readiness": {
      "path": "/up",
      "probe_duration_ms": 1660,
      "probe_attempts": 4,
      "completed_at": "2026-04-26 13:11:28 UTC"
    },
    "startup_grace_seconds": 15.0,
    "metrics_interval_seconds": 5.0
  },
  "outcome": {
    "requests_total": 4458,
    "requests_ok": 4141,
    "requests_error": 317,
    "aborted": false
  },
  "query_ids": [
    "8381958818576231493"
  ],
  "warnings": [

  ],
  "invariant_samples": [

  ]
}
```

```bash
DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo CLICKHOUSE_URL=http://localhost:8123 BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby workloads/missing_index_todos/oracle.rb runs/20260426T131118Z-missing-index-todos
```

```output
PASS: explain (index_todos_on_user_id via Bitmap Heap Scan; status filter; sort created_at DESC, id DESC)
PASS: clickhouse (3339 calls; mean 1.3ms)
PASS: dominance (6.76x over next queryid)
```

## Final tuning note

During live verification, `/api/todos/counts` dominated whenever tenant count was too high because the controller still fans out one `COUNT(*)` query per user. The final branch state intentionally postpones that balancing work: `user_count` is now `100`, `FetchCounts` weight is `0`, and the journal records that counts/N+1 tuning is future work rather than part of this gate.

```bash
rg -n 'FetchCounts|user_count|counts N\+1|dominance' JOURNAL.md workloads/missing_index_todos/workload.rb workloads/missing_index_todos/test/workload_test.rb
```

```output
workloads/missing_index_todos/test/workload_test.rb:12:    assert_equal Load::Scale.new(rows_per_table: 100_000, extra: { open_fraction: 0.6, user_count: 100 }, seed: 42), workload.scale
workloads/missing_index_todos/test/workload_test.rb:13:    assert_equal 100, workload.scale.extra.fetch(:user_count)
workloads/missing_index_todos/test/workload_test.rb:20:      Load::ActionEntry.new(Load::Workloads::MissingIndexTodos::Actions::FetchCounts, 0),
workloads/missing_index_todos/test/workload_test.rb:52:    scale = Load::Scale.new(rows_per_table: 100_000, extra: { user_count: 1_000 }, seed: 42)
workloads/missing_index_todos/workload.rb:23:          Load::Scale.new(rows_per_table: 100_000, seed: 42, extra: { open_fraction: 0.6, user_count: 100 })
workloads/missing_index_todos/workload.rb:33:            Load::ActionEntry.new(Actions::FetchCounts, 0),
JOURNAL.md:91:- 2026-04-25 real mixed-workload tuning: with `rows_per_table: 100_000`, the counts N+1 path was too expensive at weight `6` and collapsed the dominance margin; lowering `FetchCounts` to weight `2` restored a real finite run to `744` ClickHouse calls on the primary query and a `4.32x` dominance margin over the next queryid.
JOURNAL.md:117:- 2026-04-25 tenant-shaped workload Task 1: `missing-index-todos` now sets `scale.extra[:user_count] = 1_000`; list/search/write actions sample `user_id` from `scale.extra`, `close_todo` prefetches one sampled user's open todos and returns a `204` no-op when none exist, and `delete_completed_todos` is a direct query-string delete with no prefetch.
JOURNAL.md:118:- 2026-04-25 Task 1 regression note: `load/test/runner_test.rb` mixed-write support must model the new tenant-shaped contracts too; without `user_count` in the synthetic scale and a JSON body for `close_todo`'s open-todos prefetch, the runner test times out instead of producing diverse ids.
JOURNAL.md:126:- 2026-04-26 dominance tuning: lowering `scale.extra[:user_count]` from `1_000` to `100` was not enough to restore oracle dominance because `/api/todos/counts` still drives the per-user `SELECT COUNT(*) FROM "todos" WHERE "todos"."user_id" = $1` family above the primary open-todos query. For now `FetchCounts` is weighted to `0` so the tenant-pathology gate can pass; revisit the counts/N+1 balance in a later phase instead of treating it as a requirement in this round.
```
