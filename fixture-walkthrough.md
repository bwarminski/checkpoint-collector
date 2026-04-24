# Fixture Harness Replacement Walkthrough

*2026-04-22T07:59:17Z by Showboat 0.6.1*
<!-- showboat-id: f694e93c-897f-45b6-bf20-260b4bf3aa33 -->

This walkthrough explains the load-runner and Rails adapter code introduced on this branch in the same order the system executes.

It starts at `bin/load`, follows workload loading and runner orchestration, then shows how artifacts are written, how the Rails adapter manages database and process state, and how the missing-index oracle proves the pathology.

## 1. Branch surface

The first thing to anchor is the branch delta itself. These are the files that define the new runtime path we need to understand.

```bash
git log --oneline 264f2b0..HEAD; echo ---; git diff --name-only 264f2b0..HEAD | sort
```

```output
7f8ee91 fix: align adapter command args with spec
4e08407 fix: stabilize run record artifacts
5e385ce fix: persist load run artifacts and query ids
916945f fix: handle load runner termination signals
7881180 fix: record adapter command logs
24f51ec fix: stop rails process groups
---
adapters/rails/bin/bench-adapter
adapters/rails/lib/rails_adapter/commands/reset_state.rb
adapters/rails/lib/rails_adapter/commands/stop.rb
adapters/rails/lib/rails_adapter/result.rb
adapters/rails/test/reset_state_test.rb
adapters/rails/test/stop_test.rb
adapters/rails/test/test_helper.rb
bin/load
load/lib/load/adapter_client.rb
load/lib/load/cli.rb
load/lib/load/client.rb
load/lib/load/run_record.rb
load/lib/load/runner.rb
load/test/adapter_client_test.rb
load/test/cli_test.rb
load/test/rate_limiter_test.rb
load/test/run_record_test.rb
load/test/runner_test.rb
```

## 2. Entry point: `bin/load`

`bin/load` is intentionally thin. It installs real `SIGINT` and `SIGTERM` traps around the CLI invocation and lets `Load::CLI` own help, version, and `run` parsing.

Those traps feed a shared stop flag into the runner so worker shutdown and adapter cleanup happen cooperatively.

```bash
sed -n 1,220p bin/load
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
```

## 3. CLI parsing and workload discovery: `Load::CLI`

`Load::CLI` converts command-line flags into a concrete runtime:

- parse the run options
- resolve the requested workload name through `Load::WorkloadRegistry`
- create `RunRecord` and `AdapterClient`
- instantiate `Runner` with the shared stop flag and metrics interval

This is where the generic runtime gets bound to one workload and one adapter binary.

```bash
sed -n 1,260p load/lib/load/cli.rb
```

```output
# ABOUTME: Parses the load runner CLI and resolves named workloads.
# ABOUTME: Keeps command handling separate from runner orchestration.
require "optparse"
require "tmpdir"

module Load
  class CLI
    USAGE = "Usage: bin/load run --workload NAME --adapter PATH --app-root PATH [--readiness-path /up|none] [--startup-grace-seconds 15] [--metrics-interval-seconds 5]".freeze

    def initialize(argv:, version:, runner: nil, stop_flag: nil, stdout: $stdout, stderr: $stderr)
      @argv = argv.dup
      @version = version
      @runner = runner || default_runner
      @stop_flag = stop_flag || Load::Runner::InternalStopFlag.new
      @stdout = stdout
      @stderr = stderr
    end

    def run
      command = @argv.shift

      case command
      when "run"
        run_command
      when "--help", "-h", nil
        @stdout.puts(USAGE)
        0
      when "--version", "-v"
        @stdout.puts(@version)
        0
      else
        @stderr.puts("unknown command: #{command}")
        usage_error
      end
    rescue OptionParser::ParseError, ArgumentError => error
      @stderr.puts(error.message)
      usage_error
    rescue StandardError => error
      @stderr.puts(error.message)
      2
    end

    private

    def run_command
      options = parse_options
      workload = load_workload(options.fetch(:workload))
      runner = @runner.call(
        workload: workload,
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

    def default_runner
      lambda do |workload:, adapter_bin:, app_root:, runs_dir:, readiness_path:, startup_grace_seconds:, metrics_interval_seconds:, stop_flag:, stdout:, stderr:|
        run_dir = File.join(runs_dir, "#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}-#{workload.name}")
        run_record = Load::RunRecord.new(run_dir:)
        adapter_client = Load::AdapterClient.new(adapter_bin:, run_record:)
        Load::Runner.new(
          workload:,
          adapter_client:,
          run_record:,
          clock: -> { Time.now.utc },
          sleeper: ->(seconds) { sleep(seconds) },
          readiness_path:,
          startup_grace_seconds:,
          metrics_interval_seconds:,
          app_root:,
          adapter_bin:,
          stop_flag:,
        )
      end
    end

    def parse_options
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
        parser.on("--readiness-path PATH") { |value| options[:readiness_path] = value == "none" ? "none" : value }
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
      2
    end

    def workload_path(name)
      File.expand_path("../../../workloads/#{name.tr("-", "_")}/workload", __dir__)
    end
  end
end
```

## 4. The core type layer

The `Load` namespace is deliberately small. The base classes and `Data.define` value objects establish the contract that every workload and worker follows:

- `Action`: one executable request type
- `ActionEntry`: an action plus weight
- `Scale`: workload scale inputs and their env-var projection
- `LoadPlan`: workers, duration, rate limit, seed
- `Workload`: the interface that concrete workloads implement

These types are what make the generic runner possible.

```bash
sed -n 1,220p load/lib/load.rb; echo ---; sed -n 1,220p load/lib/load/action.rb; echo ---; sed -n 1,220p load/lib/load/action_entry.rb; echo ---; sed -n 1,220p load/lib/load/load_plan.rb; echo ---; sed -n 1,220p load/lib/load/scale.rb; echo ---; sed -n 1,220p load/lib/load/workload.rb
```

```output
# ABOUTME: Defines the top-level namespace for the load runner.
# ABOUTME: Loads the load runner foundation classes and value objects.
require_relative "load/action"
require_relative "load/action_entry"
require_relative "load/adapter_client"
require_relative "load/cli"
require_relative "load/client"
require_relative "load/load_plan"
require_relative "load/metrics"
require_relative "load/rate_limiter"
require_relative "load/reporter"
require_relative "load/run_record"
require_relative "load/runner"
require_relative "load/scale"
require_relative "load/selector"
require_relative "load/worker"
require_relative "load/workload"
require_relative "load/workload_registry"

module Load
end
---
# ABOUTME: Declares the base class for load runner actions.
# ABOUTME: Concrete actions provide their own name and execution behavior.
module Load
  class Action
    def initialize(rng:, ctx:, client:)
      @rng = rng
      @ctx = ctx
      @client = client
    end

    attr_reader :rng, :ctx, :client

    def name
      raise NotImplementedError
    end

    def call
      raise NotImplementedError
    end
  end
end
---
# ABOUTME: Describes one selectable action and its selection weight.
# ABOUTME: The selector uses these entries to choose actions deterministically.
module Load
  ActionEntry = Data.define(:action_class, :weight)
end
---
# ABOUTME: Describes how a workload should be executed.
# ABOUTME: Stores worker count, runtime, rate limit, and seed.
module Load
  LoadPlan = Data.define(:workers, :duration_seconds, :rate_limit, :seed) do
    def initialize(workers:, duration_seconds:, rate_limit: :unlimited, seed: nil)
      super
    end
  end
end
---
# ABOUTME: Describes the scale parameters for a workload.
# ABOUTME: Exposes environment variable pairs for non-nil scale fields.
module Load
  Scale = Data.define(:rows_per_table, :open_fraction, :seed) do
    def initialize(rows_per_table:, open_fraction: nil, seed: 42)
      super
    end

    def env_pairs
      to_h.each_with_object({}) do |(key, value), pairs|
        next if key == :seed || value.nil?

        pairs[key.to_s.upcase] = value
      end
    end
  end
end
---
# ABOUTME: Declares the base class for a runnable workload.
# ABOUTME: Concrete workloads provide the name, scale, actions, and plan.
module Load
  class Workload
    def name
      raise NotImplementedError
    end

    def scale
      raise NotImplementedError
    end

    def actions
      raise NotImplementedError
    end

    def load_plan
      raise NotImplementedError
    end
  end
end
```

## 5. The runner high-level lifecycle

`Load::Runner` is the center of the system. Its `run` method executes the lifecycle in order:

1. Write the initial run skeleton.
2. Call `adapter.describe` and persist adapter metadata.
3. Call `prepare`.
4. Call `reset_state`, including workload-specific `query_ids` capture.
5. Call `start` and record `pid` plus `base_url`.
6. Run readiness.
7. Start workers and the reporter.
8. Finish the run and always call `adapter.stop` in `ensure`.

The same file also owns readiness behavior, worker draining, and abort handling.

```bash
sed -n 1,220p load/lib/load/runner.rb
```

```output
# ABOUTME: Orchestrates adapter lifecycle, readiness probing, and worker execution.
# ABOUTME: Writes run state as workers report the first successful response.
require "net/http"
require "thread"
require "time"

module Load
  class Runner
    WORKER_DRAIN_TIMEOUT_SECONDS = 1.0

    def initialize(workload:, adapter_client:, run_record:, clock:, sleeper:, http: Net::HTTP, readiness_timeout_seconds: 15, readiness_path: "/up", startup_grace_seconds: 15, metrics_interval_seconds: 5, app_root: nil, adapter_bin: nil, stop_flag: nil)
      @workload = workload
      @adapter_client = adapter_client
      @run_record = run_record
      @clock = clock
      @sleeper = sleeper
      @http = http
      @readiness_timeout_seconds = readiness_timeout_seconds
      @readiness_path = readiness_path
      @startup_grace_seconds = startup_grace_seconds
      @metrics_interval_seconds = metrics_interval_seconds
      @app_root = app_root
      @adapter_bin = adapter_bin
      @stop_flag = stop_flag || InternalStopFlag.new
      @state_mutex = Mutex.new
      @request_totals = { total: 0, ok: 0, error: 0 }
      @state = initial_state
      @window_started = false
    end

    def run
      @run_record.write_run(snapshot_state)
      adapter_describe = @adapter_client.describe
      validate_adapter_response!(adapter_describe, %w[name framework runtime], "describe")
      write_state(adapter: {
        describe: adapter_describe,
        bin: @adapter_bin || @adapter_client.adapter_bin,
        app_root: @app_root,
      })

      @adapter_client.prepare(app_root: @app_root)
      reset_state = @adapter_client.reset_state(app_root: @app_root, workload: @workload.name, scale: @workload.scale)
      write_state(query_ids: Array(reset_state["query_ids"]).map(&:to_s)) if reset_state.is_a?(Hash) && reset_state["query_ids"]

      start_response = @adapter_client.start(app_root: @app_root)
      validate_adapter_response!(start_response, %w[pid base_url], "start")
      write_state(adapter: { pid: start_response.fetch("pid"), base_url: start_response.fetch("base_url") })

      probe_readiness(start_response.fetch("base_url"))
      start_workers(start_response.fetch("base_url"))

      finish_run
    rescue AdapterClient::AdapterError => error
      write_state(outcome: outcome_payload(aborted: true, error_code: "adapter_error"))
      1
    rescue ReadinessTimeout
      write_state(outcome: outcome_payload(aborted: true, error_code: "readiness_timeout"))
      1
    ensure
      begin
        @adapter_client.stop(pid: @state.dig(:adapter, :pid)) if @state.dig(:adapter, :pid)
      rescue AdapterClient::AdapterError
        write_state(outcome: outcome_payload(aborted: true, error_code: "adapter_error"))
        return 1
      end
    end

    private

    def probe_readiness(base_url)
      return sleep_startup_grace if @readiness_path == "none"

      client = Load::Client.new(base_url: base_url, http: @http)
      probe_started_at = current_time
      deadline = current_time + @startup_grace_seconds
      backoff = 0.2
      attempts = 0

      loop do
        raise ReadinessTimeout if current_time >= deadline

        attempts += 1
        response = client.get(@readiness_path)
        raise ReadinessTimeout if current_time >= deadline

        if response.code.to_i >= 200 && response.code.to_i < 300
          write_state(window: { readiness: readiness_payload(probe_started_at:, attempts:) })
          return
        end

        raise ReadinessTimeout if current_time >= deadline

        sleep_for = [backoff, deadline - current_time].min
        @sleeper.call(sleep_for)
        backoff = [backoff * 2, 1.6].min
      rescue StandardError
        raise ReadinessTimeout if current_time >= deadline

        sleep_for = [backoff, deadline - current_time].min
        @sleeper.call(sleep_for)
        backoff = [backoff * 2, 1.6].min
      end
    end

    def sleep_startup_grace
      @sleeper.call(@startup_grace_seconds)
      started_at = current_time
      write_state(
        window: {
          readiness: readiness_payload(
            probe_started_at: started_at,
            attempts: 0,
            duration_ms: (@startup_grace_seconds * 1000).round,
            path: "none",
          ),
        },
      )
    end

    def start_workers(base_url)
      plan = @workload.load_plan
      client = Load::Client.new(base_url: base_url, http: @http)
      rate_limiter = Load::RateLimiter.new(rate_limit: plan.rate_limit, clock: @clock, sleeper: @sleeper)
      entries = @workload.actions
      seed = plan.seed.nil? ? @workload.scale.seed : plan.seed

      workers = Array.new(plan.workers) do |index|
        buffer = tracking_buffer
        Load::Worker.new(
          worker_id: index + 1,
          selector: Load::Selector.new(entries: entries, rng: Random.new(seed + index)),
          buffer: buffer,
          client: client,
          ctx: { base_url: base_url },
          rng: Random.new(seed + index),
          rate_limiter: rate_limiter,
          stop_flag: @stop_flag,
        )
      end

      reporter = Load::Reporter.new(
        workers:,
        interval_seconds: @metrics_interval_seconds,
        sink: metrics_sink,
        clock: @clock,
        sleeper: @sleeper,
      )
      reporter.start
      threads = workers.map { |worker| Thread.new { worker.run } }
      wait_for_window_end(plan.duration_seconds)
      drain_workers(threads)
      reporter.stop
    end

    def wait_for_window_end(duration_seconds)
      deadline = current_time + duration_seconds

      until @stop_flag.call
        remaining = deadline - current_time
        if remaining <= 0
          @stop_flag.trigger(:timeout) if @stop_flag.respond_to?(:trigger)
          break
        end

        Thread.pass
        next if @stop_flag.call

        remaining = deadline - current_time
        next if remaining <= 0

        @sleeper.call([1.0, remaining].min)
      end
    end

    def drain_workers(threads)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + WORKER_DRAIN_TIMEOUT_SECONDS

      threads.each do |thread|
        remaining = [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max
        thread.join(remaining)
        next unless thread.alive?

        thread.raise(DrainTimeout)
        thread.join(0.1)
        thread.kill if thread.alive?
      end
    end

    def finish_run
      write_state(window: { end_ts: current_time })
      if @window_started
        write_state(outcome: outcome_payload(aborted: stop_aborted?))
        return 0
      end

      write_state(outcome: outcome_payload(aborted: true, error_code: "no_successful_requests"))
      3
    end

    def stop_aborted?
      return false unless @stop_flag.respond_to?(:reason)

      %i[sigint sigterm].include?(@stop_flag.reason)

    end

    def tracking_buffer
      callback = method(:pin_window_start)
      ok_callback = method(:record_request_ok)
      error_callback = method(:record_request_error)

      Class.new(Load::Metrics::Buffer) do
        define_method(:initialize) do |callback, ok_callback, error_callback|
          super()
          @callback = callback
          @ok_callback = ok_callback
          @error_callback = error_callback
          @started = false
        end

```

## 6. How the runner records state

The second half of `Runner` explains why the run artifacts are trustworthy:

- `initial_state` lays out the full `run.json` schema up front.
- `readiness_payload` and `outcome_payload` keep incremental writes consistent.
- `write_state` deep-merges fragments into the current state and deep-copies the snapshot before writing.
- `RunRecord#write_run` is atomic, so a concurrent read does not see a truncated file.

This is where the runner records request totals and the final abort or error state.

```bash
sed -n 220,420p load/lib/load/runner.rb; echo ---; sed -n 1,220p load/lib/load/run_record.rb
```

```output

        define_method(:record_ok) do |**kwargs|
          super(**kwargs)
          @ok_callback.call
          return if @started

          @started = true
          @callback.call
        end

        define_method(:record_error) do |**kwargs|
          super(**kwargs)
          @error_callback.call
        end
      end.new(callback, ok_callback, error_callback)
    end

    def pin_window_start
      snapshot = nil
      @state_mutex.synchronize do
        return if @window_started

        @window_started = true
        @state = deep_merge(@state, window: { start_ts: current_time })
        snapshot = snapshot_state
      end
      @run_record.write_run(snapshot)
    end

    def current_time
      @clock.call
    end

    def metrics_sink
      run_record = @run_record
      Object.new.tap do |sink|
        sink.define_singleton_method(:<<) do |line|
          run_record.append_metrics(line)
        end
      end
    end

    def initial_state
      {
        run_id: File.basename(@run_record.run_dir),
        workload: {
          name: @workload.name,
          file: workload_file,
          scale: @workload.scale.to_h,
          load_plan: @workload.load_plan.to_h,
          actions: @workload.actions.map { |entry| { class: entry.action_class.name, weight: entry.weight } },
        },
        adapter: {
          describe: nil,
          bin: @adapter_bin || @adapter_client.adapter_bin,
          app_root: @app_root,
          base_url: nil,
          pid: nil,
        },
        window: {
          start_ts: nil,
          end_ts: nil,
          readiness: {
            path: @readiness_path,
            probe_duration_ms: nil,
            probe_attempts: nil,
          },
          startup_grace_seconds: @startup_grace_seconds,
          metrics_interval_seconds: @metrics_interval_seconds,
        },
        outcome: outcome_payload(aborted: false),
        query_ids: [],
      }
    end

    def workload_file
      path = @workload.class.instance_method(:name).source_location&.first
      return nil unless path

      expanded = File.expand_path(path)
      cwd = "#{Dir.pwd}/"
      expanded.start_with?(cwd) ? expanded.delete_prefix(cwd) : expanded
    end

    def readiness_payload(probe_started_at:, attempts:, duration_ms: nil, path: @readiness_path)
      {
        completed_at: current_time,
        path:,
        probe_duration_ms: duration_ms || ((current_time - probe_started_at) * 1000).round,
        probe_attempts: attempts,
      }
    end

    def outcome_payload(aborted:, error_code: nil)
      {
        requests_total: @request_totals.fetch(:total),
        requests_ok: @request_totals.fetch(:ok),
        requests_error: @request_totals.fetch(:error),
        aborted:,
        error_code:,
      }.compact
    end

    def snapshot_state
      deep_copy(@state)
    end

    def record_request_ok
      @state_mutex.synchronize do
        @request_totals[:total] += 1
        @request_totals[:ok] += 1
      end
    end

    def record_request_error
      @state_mutex.synchronize do
        @request_totals[:total] += 1
        @request_totals[:error] += 1
      end
    end

    def write_state(fragment)
      snapshot = nil
      @state_mutex.synchronize do
        @state = deep_merge(@state, fragment)
        snapshot = snapshot_state
      end
      @run_record.write_run(snapshot)
    end

    def validate_adapter_response!(response, required_keys, response_name)
      raise AdapterClient::AdapterError, "invalid adapter #{response_name} response" unless response.is_a?(Hash)

      required_keys.each { |key| response.fetch(key) }
    rescue KeyError
      raise AdapterClient::AdapterError, "invalid adapter #{response_name} response"
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

    class InternalStopFlag
      attr_reader :reason

      def initialize
        @reason = nil
      end

      def trigger(reason)
        @reason = reason
      end

      def call
        !@reason.nil?
      end
    end

    class ReadinessTimeout < StandardError
    end

    class DrainTimeout < StandardError
    end
  end
end
---
# ABOUTME: Writes run metadata and append-only JSONL artifacts for a run.
# ABOUTME: Keeps the run directory layout simple for runner orchestration.
require "fileutils"
require "json"

module Load
  class RunRecord
    def initialize(run_dir:)
      @run_dir = run_dir
      FileUtils.mkdir_p(@run_dir)
    end

    attr_reader :run_dir

    def run_path
      File.join(@run_dir, "run.json")
    end

    def metrics_path
      File.join(@run_dir, "metrics.jsonl")
    end

    def adapter_commands_path
      File.join(@run_dir, "adapter-commands.jsonl")
    end

    def write_run(payload)
      temp_path = "#{run_path}.tmp"
      File.write(temp_path, JSON.pretty_generate(payload) + "\n")
      File.rename(temp_path, run_path)
    end

    def append_metrics(payload)
      append_jsonl(metrics_path, payload)
    end

    def append_adapter_command(payload)
      append_jsonl(adapter_commands_path, payload)
    end

    private

    def append_jsonl(path, payload)
      File.open(path, "a") do |file|
        file.puts(JSON.generate(payload))
      end
    end
  end
end
```

## 7. Worker-side execution primitives

Once the runner has a started app and a readiness decision, it delegates the live request loop to a small set of runtime primitives:

- `Client` issues HTTP requests with explicit timeouts.
- `Selector` turns weighted action entries into deterministic picks.
- `RateLimiter` serializes finite-rate admission across all workers.
- `Worker` instantiates actions, executes requests, and records ok or error outcomes in its buffer.
- `Metrics::Buffer` and `Metrics::Snapshot` collect interval data.
- `Reporter` periodically drains all worker buffers and writes `metrics.jsonl`.

Together these files are the replacement for the old single-purpose harness loop.

```bash
sed -n 1,220p load/lib/load/client.rb; echo ---; sed -n 1,220p load/lib/load/selector.rb; echo ---; sed -n 1,220p load/lib/load/rate_limiter.rb; echo ---; sed -n 1,240p load/lib/load/worker.rb; echo ---; sed -n 1,220p load/lib/load/metrics.rb; echo ---; sed -n 1,220p load/lib/load/reporter.rb
```

```output
# ABOUTME: Issues HTTP requests against the application under test.
# ABOUTME: Wraps Net::HTTP with a base URL and simple request helpers.
require "net/http"
require "uri"

module Load
  class Client
    HTTP_TIMEOUT_SECONDS = 5

    def initialize(base_url:, http: Net::HTTP)
      @base_url = URI(base_url)
      @http = http
    end

    def get(path)
      request(:get, path)
    end

    def request(method, path)
      uri = uri_for(path)

      @http.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        configure_timeouts(http)
        request_class = Net::HTTP.const_get(method.to_s.capitalize)
        http.request(request_class.new(uri))
      end
    end

    private

    def uri_for(path)
      URI.join(@base_url.to_s.end_with?("/") ? @base_url.to_s : "#{@base_url}/", path.sub(/\A\//, ""))
    end

    def configure_timeouts(http)
      http.open_timeout = HTTP_TIMEOUT_SECONDS if http.respond_to?(:open_timeout=)
      http.read_timeout = HTTP_TIMEOUT_SECONDS if http.respond_to?(:read_timeout=)
      http.write_timeout = HTTP_TIMEOUT_SECONDS if http.respond_to?(:write_timeout=)
    end
  end
end
---
# ABOUTME: Selects actions from a weighted list using a seeded random source.
# ABOUTME: Precomputes cumulative weights for repeatable picks.
module Load
  class Selector
    def initialize(entries:, rng:)
      @entries = entries
      @rng = rng
      @thresholds = []
      total_weight = 0

      entries.each do |entry|
        total_weight += entry.weight
        @thresholds << total_weight
      end

      @total_weight = total_weight
    end

    def next
      ticket = @rng.rand * @total_weight
      index = @thresholds.bsearch_index { |threshold| threshold > ticket }
      @entries.fetch(index)
    end
  end
end
---
# ABOUTME: Spaces requests according to a shared rate limit.
# ABOUTME: Preserves the limiter timing behavior used by the fixture harness.
require "thread"

module Load
  class RateLimiter
    def initialize(rate_limit:, clock:, sleeper:)
      @rate_limit = rate_limit
      @clock = clock
      @sleeper = sleeper
      @next_allowed_at = nil
      @mutex = Mutex.new
    end

    def wait_turn
      @mutex.synchronize do
        return if @rate_limit == :unlimited

        now = @clock.call
        @next_allowed_at ||= now
        sleep_for = @next_allowed_at - now
        @sleeper.call(sleep_for) if sleep_for.positive?
        @next_allowed_at = [@next_allowed_at, now].max + (1.0 / @rate_limit)
      end
    end
  end
end
---
# ABOUTME: Runs selected actions, records outcomes, and keeps the worker loop moving.
# ABOUTME: Captures selector and action failures in the worker's own metrics buffer.
module Load
  class Worker
    def initialize(worker_id:, selector:, buffer:, client:, ctx:, rng:, rate_limiter:, stop_flag:)
      @worker_id = worker_id
      @selector = selector
      @buffer = buffer
      @client = client
      @ctx = ctx
      @rng = rng
      @rate_limiter = rate_limiter
      @stop_flag = stop_flag
    end

    attr_reader :buffer

    def run
      until @stop_flag.call
        started_ns = monotonic_ns
        action = nil
        request_started_ns = nil

        begin
          @rate_limiter.wait_turn
          entry = @selector.next
          action = entry.action_class.new(rng: @rng, ctx: @ctx, client: @client)
          request_started_ns = monotonic_ns
          response = action.call
          @buffer.record_ok(action: action.name, latency_ns: elapsed_ns(request_started_ns), status: response.code.to_i)
        rescue StandardError => error
          @buffer.record_error(action: action_name(action), latency_ns: request_started_ns ? elapsed_ns(request_started_ns) : 0, error_class: error.class.name)
        end
      end
    end

    private

    def action_name(action)
      return :unknown unless action && action.respond_to?(:name)

      action.name
    rescue StandardError
      :unknown
    end

    def elapsed_ns(started_ns)
      monotonic_ns - started_ns
    end

    def monotonic_ns
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    end
  end
end
---
# ABOUTME: Collects per-action request latencies and outcome counts in memory.
# ABOUTME: Builds interval snapshots for reporter output and run records.
module Load
  module Metrics
    class Buffer
      def initialize
        @mutex = Mutex.new
        @data = fresh_data
      end

      def record_ok(action:, latency_ns:, status:)
        @mutex.synchronize do
          bucket = (@data[action] ||= fresh_bucket)
          bucket[:latencies_ns] << latency_ns
          bucket[:status_counts][status.to_s] += 1
        end
      end

      def record_error(action:, latency_ns:, error_class:)
        @mutex.synchronize do
          bucket = (@data[action] ||= fresh_bucket)
          bucket[:latencies_ns] << latency_ns
          bucket[:errors_by_class][error_class] += 1
        end
      end

      def swap!
        @mutex.synchronize do
          current = @data
          @data = fresh_data
          current
        end
      end

      private

      def fresh_data
        {}
      end

      def fresh_bucket
        {
          latencies_ns: [],
          status_counts: Hash.new(0),
          errors_by_class: Hash.new(0),
        }
      end
    end

    class Snapshot
      def self.build(snapshot)
        snapshot.each_with_object({}) do |(action, bucket), stats|
          latencies_ns = bucket.fetch(:latencies_ns, [])
          stats[action] = {
            count: latencies_ns.length,
            error_count: bucket.fetch(:errors_by_class, {}).values.sum,
            p50_ms: percentile_ms(latencies_ns, 0.50),
            p95_ms: percentile_ms(latencies_ns, 0.95),
            p99_ms: upper_percentile_ms(latencies_ns, 0.99),
            max_ms: max_ms(latencies_ns),
            status_counts: bucket.fetch(:status_counts, {}).dup,
            errors_by_class: bucket.fetch(:errors_by_class, {}).dup,
          }
        end
      end

      def self.percentile_ms(latencies_ns, percentile)
        return 0.0 if latencies_ns.empty?

        sorted = latencies_ns.sort
        index = (percentile * (sorted.length - 1)).floor
        sorted.fetch(index).fdiv(1_000_000)
      end
      private_class_method :percentile_ms

      def self.upper_percentile_ms(latencies_ns, percentile)
        return 0.0 if latencies_ns.empty?

        sorted = latencies_ns.sort
        index = (percentile * (sorted.length - 1)).ceil
        sorted.fetch(index).fdiv(1_000_000)
      end
      private_class_method :upper_percentile_ms

      def self.max_ms(latencies_ns)
        return 0.0 if latencies_ns.empty?

        latencies_ns.max.fdiv(1_000_000)
      end
      private_class_method :max_ms
    end
  end
end
---
# ABOUTME: Merges worker buffers into interval snapshots for later writing.
# ABOUTME: Provides an explicit snapshot_once hook and a final flush on stop.
module Load
  class Reporter
    class Shutdown < StandardError; end

    def initialize(workers:, interval_seconds:, sink:, clock:, sleeper:)
      @workers = workers
      @interval_seconds = interval_seconds
      @sink = sink
      @clock = clock
      @sleeper = sleeper
      @thread = nil
      @running = false
      @mutex = Mutex.new
      @state_mutex = Mutex.new
      @sleeping = false
    end

    def start
      return self if @thread&.alive?

      @running = true
      @thread = Thread.new do
        begin
          loop do
            break unless @running
            begin
              Thread.handle_interrupt(Shutdown => :immediate) do
                mark_sleeping(true)
                @sleeper.call(@interval_seconds)
              end
            rescue StopIteration, Shutdown
              break
            ensure
              mark_sleeping(false)
            end
            break unless @running
            Thread.handle_interrupt(Shutdown => :never) do
              snapshot_once
            end
          end
        rescue Exception => error
          raise unless error == Shutdown || error.is_a?(Shutdown)
        end
      end

      self
    end

    def stop
      @running = false
      if @thread && @thread != Thread.current
        @thread.raise(Shutdown.new) if sleeping? && @thread.alive?
        @thread.join
      end
      snapshot_once
      self
    end

    def snapshot_once
      @mutex.synchronize do
        merged = {}

        @workers.each do |worker|
          worker.buffer.swap!.each do |action, bucket|
            merged[action] ||= fresh_bucket
            merged[action][:latencies_ns].concat(bucket.fetch(:latencies_ns, []))
            merged[action][:status_counts].merge!(bucket.fetch(:status_counts, {})) { |_key, left, right| left + right }
            merged[action][:errors_by_class].merge!(bucket.fetch(:errors_by_class, {})) { |_key, left, right| left + right }
          end
        end

        line = {
          ts: @clock.call,
          interval_ms: (@interval_seconds * 1000).to_i,
          actions: Load::Metrics::Snapshot.build(merged),
        }
        @sink << line
        line
      end
    end

    private

    def mark_sleeping(value)
      @state_mutex.synchronize do
        @sleeping = value
      end
    end

    def sleeping?
      @state_mutex.synchronize do
        @sleeping
      end
    end

    def fresh_bucket
      {
        latencies_ns: [],
        status_counts: Hash.new(0),
        errors_by_class: Hash.new(0),
      }
    end
  end
end
```

## 8. Adapter invocation and command logging

`Load::AdapterClient` is the runner-side shell around the external adapter binary.

Important details:

- It keeps the runner workload-neutral; the runner never talks to Rails or Postgres directly.
- It logs every adapter call to `adapter-commands.jsonl` using the spec schema:
  `ts`, `command`, `args`, `exit_code`, `duration_ms`, `stdout_json`, `stderr`.
- `args` means only the actual command arguments, not the transport-level `--json` flag or duplicated subcommand name.

This file is the bridge between the generic runner and the Rails-specific adapter.

```bash
sed -n 1,240p load/lib/load/adapter_client.rb
```

```output
# ABOUTME: Invokes the adapter binary for load runner lifecycle commands.
# ABOUTME: Captures JSON output from the adapter and forwards scale env values.
require "json"
require "open3"

module Load
  class AdapterClient
    AdapterError = Class.new(StandardError)

    def initialize(adapter_bin:, capture3: nil, run_record: nil, clock: -> { Time.now.utc })
      @adapter_bin = adapter_bin
      @capture3 = capture3 || ->(*argv) { Open3.capture3(*argv) }
      @run_record = run_record
      @clock = clock
    end

    attr_reader :adapter_bin

    def describe
      invoke("describe")
    end

    def prepare(app_root:)
      invoke("prepare", "--app-root", app_root)
    end

    def reset_state(app_root:, workload:, scale:)
      invoke(
        "reset-state",
        "--app-root", app_root,
        "--workload", workload,
        "--seed", scale.seed.to_s,
        *scale.env_pairs.flat_map { |key, value| ["--env", "#{key}=#{value}"] },
      )
    end

    def start(app_root:)
      invoke("start", "--app-root", app_root)
    end

    def stop(pid:)
      invoke("stop", "--pid", pid.to_s)
    end

    private

    def invoke(*argv)
      started_at = @clock.call
      full_argv = ["--json", *argv]
      stdout, stderr, status = @capture3.call(@adapter_bin, *full_argv)
      ended_at = @clock.call
      stdout_json = stdout.to_s.empty? ? {} : JSON.parse(stdout)
      append_adapter_command(
        ts: started_at,
        command: argv.first,
        args: argv.drop(1),
        exit_code: status.exitstatus,
        duration_ms: ((ended_at - started_at) * 1000).round,
        stdout_json:,
        stderr: stderr.to_s,
      )
      raise AdapterError, stderr unless status.success?

      stdout_json
    rescue JSON::ParserError => error
      append_adapter_command(
        ts: started_at,
        command: argv.first,
        args: argv.drop(1),
        exit_code: status&.exitstatus,
        duration_ms: started_at && ended_at ? ((ended_at - started_at) * 1000).round : nil,
        stdout_json: nil,
        stderr: stderr.to_s,
      )
      raise AdapterError, error.message
    end

    def append_adapter_command(payload)
      @run_record&.append_adapter_command(payload)
    end
  end
end
```

## 9. Rails adapter entrypoint and command dispatch

The Rails adapter is a separate CLI. `bench-adapter` parses one command plus JSON mode and dispatches into small command objects.

That split is what lets the runner stay generic while the adapter handles Rails-specific concerns like schema loading, seeding, template cloning, and process management.

```bash
sed -n 1,220p adapters/rails/bin/bench-adapter
```

```output
#!/usr/bin/env ruby
# ABOUTME: Runs the Rails benchmark adapter command-line entrypoint.
# ABOUTME: Parses command args, dispatches commands, and prints one JSON object.
require "json"
require "optparse"
require_relative "../lib/rails_adapter"

global = { json: false }
OptionParser.new do |parser|
  parser.on("--json") { global[:json] = true }
end.order!(ARGV)

command_name = ARGV.shift
options = {}

OptionParser.new do |parser|
  parser.on("--app-root PATH") { |value| options[:app_root] = value }
  parser.on("--workload NAME") { |value| options[:workload] = value }
  parser.on("--seed N", Integer) { |value| options[:seed] = value }
  parser.on("--env KEY=VALUE") do |value|
    key, env_value = value.split("=", 2)
    (options[:env_pairs] ||= {})[key] = env_value
  end
  parser.on("--pid N", Integer) { |value| options[:pid] = value }
end.parse!(ARGV)

begin
  command = case command_name
  when "describe" then RailsAdapter::Commands::Describe.new
  when "prepare" then RailsAdapter::Commands::Prepare.new(**options.slice(:app_root))
  when "migrate" then RailsAdapter::Commands::Migrate.new(**options.slice(:app_root))
  when "load-dataset" then RailsAdapter::Commands::LoadDataset.new(**options.slice(:app_root, :workload, :seed, :env_pairs))
  when "reset-state" then RailsAdapter::Commands::ResetState.new(**options.slice(:app_root, :workload, :seed, :env_pairs))
  when "start" then RailsAdapter::Commands::Start.new(**options.slice(:app_root))
  when "stop" then RailsAdapter::Commands::Stop.new(**options.slice(:pid))
  else
    result = RailsAdapter::Result.error(command_name.to_s, "unknown_command", "unknown command: #{command_name}", {})
    $stdout.puts(JSON.generate(result))
    exit 1
  end

  result = command.call
  $stdout.puts(JSON.generate(result))
  exit(result.fetch("ok") ? 0 : 1)
rescue OptionParser::ParseError => error
  result = RailsAdapter::Result.error(command_name.to_s, "parse_error", error.message, {})
  $stdout.puts(JSON.generate(result))
  exit 1
end
```

## 10. Reset-state, template caching, and query-id capture

`reset-state` is the most important Rails adapter command for this wedge.

Its flow is:

1. Decide whether a template database already exists for the current schema digest.
2. If not, build the database with `db:schema:load` plus the seeded data set.
3. If yes, clone the cached template into the benchmark database.
4. Ensure `pg_stat_statements` exists.
5. Run the workload-specific query-id capture script.
6. Reset `pg_stat_statements` again so the actual load run starts from zero counters.

The template cache keys on the schema digest, which is what makes branch and schema changes invalidate the cache automatically.

```bash
sed -n 1,240p adapters/rails/lib/rails_adapter/commands/reset_state.rb; echo ---; sed -n 1,220p adapters/rails/lib/rails_adapter/template_cache.rb
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
          Todo.where(status: "open").load
          connection = ActiveRecord::Base.connection
          query_ids = [
            %(SELECT "todos".* FROM "todos" WHERE "todos"."status" = $1),
            %(SELECT "todos".* FROM "todos" WHERE "todos"."status" = 'open'),
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
        if @template_cache.template_exists?(database_name: database_name, app_root: @app_root, env_pairs: @env_pairs)
          @template_cache.clone_template(database_name: database_name, app_root: @app_root, env_pairs: @env_pairs)
        else
          build_template
          @template_cache.build_template(database_name: database_name, app_root: @app_root, env_pairs: @env_pairs)
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
        migrate = @command_runner.capture3("bin/rails", "db:drop", "db:create", "db:schema:load", env: rails_env, chdir: @app_root, command_name: "reset-state")
        raise "db:drop db:create db:schema:load failed" unless migrate.success?

        seed = @command_runner.capture3(
          "bin/rails",
          "runner",
          %(load Rails.root.join("db/seeds.rb").to_s),
          env: rails_env.merge("SEED" => @seed.to_s).merge(@env_pairs),
          chdir: @app_root,
          command_name: "reset-state",
        )
        raise "seed runner failed" unless seed.success?
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
    end
  end
end
---
# ABOUTME: Manages the adapter-private Postgres template database for fast resets.
# ABOUTME: Uses an admin connection to create, clone, and drop the cached template.
require "digest"
require "uri"

module RailsAdapter
  class TemplateCache
    IDENTIFIER_LIMIT = 63
    TEMPLATE_SUFFIX_LENGTH = "_tmpl_".length + 12

    def initialize(pg: nil, admin_url: ENV["BENCH_ADAPTER_PG_ADMIN_URL"] || ENV["DATABASE_URL"])
      @pg = pg
      @admin_url = admin_url
    end

    def template_exists?(database_name:, app_root:, **)
      with_connection do |connection|
        connection.exec_params("SELECT 1 FROM pg_database WHERE datname = $1", [template_name(database_name, app_root:)]).ntuples.positive?
      end
    end

    def build_template(database_name:, app_root:, **)
      with_connection do |connection|
        connection.exec("CREATE DATABASE #{template_name(database_name, app_root:)} TEMPLATE #{database_name}")
      end
    end

    def clone_template(database_name:, app_root:, **)
      with_connection do |connection|
        connection.exec_params(<<~SQL, [database_name])
          SELECT pg_terminate_backend(pid)
          FROM pg_stat_activity
          WHERE datname = $1 AND pid <> pg_backend_pid()
        SQL
        connection.exec("DROP DATABASE IF EXISTS #{database_name}")
        connection.exec("CREATE DATABASE #{database_name} TEMPLATE #{template_name(database_name, app_root:)}")
      end
    end

    private

    def with_connection
      raise "BENCH_ADAPTER_PG_ADMIN_URL or DATABASE_URL is required" unless @admin_url

      uri = URI.parse(@admin_url)
      uri.path = "/postgres"
      connection = pg_driver.connect(uri.to_s)
      yield connection
    ensure
      connection&.close
    end

    def pg_driver
      return @pg if @pg

      require "pg"
      PG
    end

    def template_name(database_name, app_root:)
      digest = schema_digest(app_root)
      max_prefix_length = IDENTIFIER_LIMIT - TEMPLATE_SUFFIX_LENGTH
      prefix = database_name[0, max_prefix_length]
      "#{prefix}_tmpl_#{digest}"
    end

    def schema_digest(app_root)
      schema_path = if File.exist?(File.join(app_root, "db", "structure.sql"))
        File.join(app_root, "db", "structure.sql")
      else
        File.join(app_root, "db", "schema.rb")
      end

      Digest::SHA256.file(schema_path).hexdigest[0, 12]
    end
  end
end
```

## 11. Starting and stopping the Rails app under test

The adapter treats the Rails app as an external process.

- `start` finds a free localhost port, runs `bin/rails server`, and places it in its own process group.
- `stop` signals the process group rather than only the leader pid, so child processes do not leak between runs.
- `stop` polls with `kill(0, -pid)` and never uses `waitpid`, because start and stop happen in different adapter invocations.

This is the lifecycle contract the generic runner relies on.

```bash
sed -n 1,220p adapters/rails/lib/rails_adapter/commands/start.rb; echo ---; sed -n 1,220p adapters/rails/lib/rails_adapter/commands/stop.rb
```

```output
# ABOUTME: Spawns the benchmark Rails server on a selected localhost port.
# ABOUTME: Returns pid and base_url without detaching the child process.
module RailsAdapter
  module Commands
    class Start
      def initialize(app_root:, port_finder: RailsAdapter::PortFinder.new, spawner: RailsAdapter::ProcessSpawner.new)
        @app_root = app_root
        @port_finder = port_finder
        @spawner = spawner
      end

      def call
        port = @port_finder.next_available_port
        return RailsAdapter::Result.error("start", "port_exhausted", "no free port in 3000..3020", {}) unless port

        pid = @spawner.spawn(
          "bin/rails",
          "server",
          "-p",
          port.to_s,
          "-b",
          "127.0.0.1",
          chdir: @app_root,
          env: rails_env,
          in: "/dev/null",
          out: "/tmp/bench-adapter-#{Process.pid}-start.log",
          pgroup: true,
        )

        RailsAdapter::Result.ok("start", "pid" => pid, "base_url" => "http://127.0.0.1:#{port}")
      rescue StandardError => error
        RailsAdapter::Result.error("start", "start_failed", error.message, {})
      end

      private

      def rails_env
        RailsAdapter::Environment.benchmark(@app_root)
      end
    end
  end
end
---
# ABOUTME: Stops a benchmark Rails server process by pid using signal polling.
# ABOUTME: Avoids waitpid because start and stop run in separate adapter processes.
module RailsAdapter
  module Commands
    class Stop
      def initialize(pid:, process_killer: Process, clock: -> { Time.now.to_f }, sleeper: ->(seconds) { sleep(seconds) })
        @pid = pid
        @process_killer = process_killer
        @clock = clock
        @sleeper = sleeper
      end

      def call
        @process_killer.kill("TERM", process_group_pid)
        return RailsAdapter::Result.ok("stop") unless alive_within?(10.0)

        @process_killer.kill("KILL", process_group_pid)
        return RailsAdapter::Result.ok("stop") unless alive_within?(2.0)

        RailsAdapter::Result.error("stop", "stop_failed", "process did not exit", {})
      rescue Errno::ESRCH
        RailsAdapter::Result.ok("stop")
      end

      private

      def alive_within?(budget_seconds)
        deadline = @clock.call + budget_seconds
        loop do
          @process_killer.kill(0, process_group_pid)
          return true if @clock.call >= deadline

          @sleeper.call(0.2)
        rescue Errno::ESRCH
          return false
        end
      end

      def process_group_pid
        -@pid
      end
    end
  end
end
```

## 12. The missing-index workload itself

The workload is intentionally small. It only needs to declare enough information for the generic runtime to drive the path:

- fixed scale: `10_000_000` rows, `0.002` open fraction, seed `42`
- one action: `GET /todos/status?status=open`
- a 16-worker, 60-second unlimited-rate load plan

This is where the generic runner becomes a concrete reproducer.

```bash
sed -n 1,220p workloads/missing_index_todos/workload.rb; echo ---; sed -n 1,220p workloads/missing_index_todos/actions/list_open_todos.rb
```

```output
# ABOUTME: Defines the missing-index workload used for the todos benchmark path.
# ABOUTME: Declares the fixed scale, weighted actions, and load plan for the run.
require_relative "../../load/lib/load"
require_relative "actions/list_open_todos"

module Load
  module Workloads
    module MissingIndexTodos
      class Workload < Load::Workload
        def name
          "missing-index-todos"
        end

        def scale
          Load::Scale.new(rows_per_table: 10_000_000, open_fraction: 0.002, seed: 42)
        end

        def actions
          [Load::ActionEntry.new(Actions::ListOpenTodos, 100)]
        end

        def load_plan
          Load::LoadPlan.new(workers: 16, duration_seconds: 60, rate_limit: :unlimited, seed: nil)
        end
      end
    end
  end
end

Load::WorkloadRegistry.register("missing-index-todos", Load::Workloads::MissingIndexTodos::Workload)
---
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
            client.get("/todos/status?status=open")
          end
        end
      end
    end
  end
end
```

## 13. The workload-local oracle

The oracle is deliberately outside the runner. It is the tactical proof layer for this wedge.

Its job is:

1. Read `run.json` and recover the run window plus `query_ids`.
2. Run `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` on the canonical `todos.status = open` statement.
3. Walk the plan tree and require a `Seq Scan` on `todos` while rejecting index scans.
4. Poll ClickHouse for the recorded `query_ids` until the interval count crosses the threshold.

This is the parity check against the old fixture harness behavior.

```bash
sed -n 1,260p workloads/missing_index_todos/oracle.rb
```

```output
# ABOUTME: Verifies the missing-index workload reproduced both the bad plan and ClickHouse activity.
# ABOUTME: Reads a run record, tree-walks EXPLAIN JSON, and polls ClickHouse by queryid fingerprints.
require "json"
require "net/http"
require "optparse"
require "pg"
require "time"
require "uri"

module Load
  module Workloads
    module MissingIndexTodos
      class Oracle
        CLICKHOUSE_CALL_THRESHOLD = 500
        INDEX_SCAN_NODE_TYPES = ["Index Scan", "Index Only Scan", "Bitmap Index Scan"].freeze
        EXPLAIN_SQL = "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT * FROM todos WHERE status = 'open'"
        QUERY_TEXT_CANDIDATES = [
          %(SELECT "todos".* FROM "todos" WHERE "todos"."status" = $1),
          %(SELECT "todos".* FROM "todos" WHERE "todos"."status" = 'open'),
        ].freeze

        class Failure < StandardError
        end

        def initialize(stdout: $stdout, stderr: $stderr, pg: PG, clickhouse_query: nil, clock: -> { Time.now.utc }, sleeper: ->(seconds) { sleep(seconds) })
          @stdout = stdout
          @stderr = stderr
          @pg = pg
          @clickhouse_query = clickhouse_query || method(:query_clickhouse)
          @clock = clock
          @sleeper = sleeper
        end

        def run(argv)
          options = parse(argv)
          result = call(**options)

          @stdout.puts("PASS: explain (#{result.fetch(:plan).fetch("Node Type")} on todos, plan node confirmed)")
          @stdout.puts("PASS: clickhouse (#{result.fetch(:clickhouse).fetch("total_exec_count")} calls; mean #{result.fetch(:clickhouse).fetch("mean_exec_time_ms")}ms)")
          exit 0
        rescue Failure => error
          @stderr.puts(error.message)
          exit 1
        end

        def call(run_dir:, database_url:, clickhouse_url:, timeout_seconds: 30)
          run_record = load_run_record(run_dir)
          queryids = extract_queryids(run_record, database_url)
          plan = explain_todos_scan(database_url)
          clickhouse = wait_for_clickhouse!(
            window: run_record.fetch("window"),
            queryids:,
            clickhouse_url:,
            timeout_seconds:
          )

          {
            plan:,
            clickhouse: normalize_clickhouse_snapshot(clickhouse),
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

        def extract_queryids(run_record, database_url)
          candidates = [
            run_record["query_ids"],
            run_record["queryids"],
            run_record.dig("oracle", "query_ids"),
            run_record.dig("oracle", "queryids"),
            run_record.dig("workload", "query_ids"),
            run_record.dig("workload", "queryids"),
            run_record.dig("workload", "oracle", "query_ids"),
            run_record.dig("workload", "oracle", "queryids"),
          ].compact

          queryids = Array(candidates.first).map(&:to_s).reject(&:empty?).uniq
          return queryids unless queryids.empty?

          queryids = lookup_queryids(database_url)
          raise Failure, "FAIL: run record is missing query_ids and pg_stat_statements had no matching queryids" if queryids.empty?

          queryids
        end

        def explain_todos_scan(database_url)
          connection = @pg.connect(database_url)
          rows = connection.exec(EXPLAIN_SQL)
          payload = JSON.parse(rows.first.fetch("QUERY PLAN"))
          plan = payload.fetch(0).fetch("Plan")
          todos_nodes = relation_nodes(plan, "todos")
          raise Failure, "FAIL: explain (could not find todos in plan)" if todos_nodes.empty?

          rejected_node = todos_nodes.find { |node| INDEX_SCAN_NODE_TYPES.include?(node.fetch("Node Type")) }
          raise Failure, "FAIL: explain (expected Seq Scan, got #{rejected_node.fetch("Node Type")})" if rejected_node

          seq_scan = todos_nodes.find { |node| node.fetch("Node Type") == "Seq Scan" }
          return seq_scan if seq_scan

          raise Failure, "FAIL: explain (expected Seq Scan, got #{todos_nodes.first.fetch("Node Type")})"
        ensure
          connection&.close
        end

        def lookup_queryids(database_url)
          connection = @pg.connect(database_url)
          queryids = QUERY_TEXT_CANDIDATES.flat_map do |query_text|
            connection.exec_params(
              "SELECT DISTINCT queryid::text AS queryid FROM pg_stat_statements WHERE query = $1",
              [query_text],
            ).map { |row| row.fetch("queryid") }
          end

          queryids.uniq
        ensure
          connection&.close
        end

        def relation_nodes(node, relation_name)
          matches = []
          matches << node if node["Relation Name"] == relation_name
          Array(node["Plans"]).each do |child|
            matches.concat(relation_nodes(child, relation_name))
          end
          matches
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

        def query_clickhouse(window:, queryids:, clickhouse_url:)
          uri = URI.parse(clickhouse_url)
          uri.path = "/" if uri.path.nil? || uri.path.empty?
          uri.query = URI.encode_www_form(query: "#{build_clickhouse_sql(window:, queryids:)} FORMAT JSONEachRow")
          response = Net::HTTP.get_response(uri)
          raise Failure, "FAIL: clickhouse (query failed: #{response.code} #{response.body})" if response.code.to_i >= 400

          body = response.body.to_s.each_line.first || "{\"total_exec_count\":\"0\",\"mean_exec_time_ms\":\"0.0\"}"
          JSON.parse(body)
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
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  Load::Workloads::MissingIndexTodos::Oracle.new.run(ARGV)
end
```

## 14. End-to-end mental model

Putting the pieces together:

- `bin/load` creates the shared stop flag and hands off to `Load::CLI`.
- `Load::CLI` loads one workload file, builds a `RunRecord`, creates an `AdapterClient`, and instantiates `Runner`.
- `Runner` captures adapter metadata, resets the benchmark state through the Rails adapter, starts the app, probes readiness, launches workers, and continuously writes `run.json` plus `metrics.jsonl`.
- `AdapterClient` logs each lifecycle command to `adapter-commands.jsonl`.
- The Rails adapter clones or rebuilds the benchmark database, captures canonical query ids for this workload, and manages the Rails server process group.
- The workload file defines what traffic to send.
- The oracle reads the run record and proves the pathology landed in both Postgres `EXPLAIN` and ClickHouse.

That is the complete replacement path for the old fixture harness on this branch.
