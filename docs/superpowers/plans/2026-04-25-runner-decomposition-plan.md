# Runner Decomposition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract `RunState`, `InvariantMonitor`, and `LoadExecution` from `Load::Runner` without changing CLI behavior, run artifacts, or invariant-policy semantics.

**Architecture:** Keep `Load::Runner` as the top-level use-case shell and move its three densest subordinate concerns into focused collaborators. `RunState` owns `run.json` schema and persistence, `InvariantMonitor` owns the sampling thread and breach policy, and `LoadExecution` owns workers, reporter lifecycle, and load-window execution.

**Tech Stack:** Ruby, Minitest, existing `Load::*` runtime classes, file-backed `Load::RunRecord`

---

## File Map

**Create:**
- `load/lib/load/run_state.rb` — owns the mutable run payload, persistence, and outcome shaping
- `load/lib/load/invariant_monitor.rb` — owns invariant thread lifecycle and `enforce|warn|off` policy
- `load/lib/load/load_execution.rb` — owns worker construction, reporter lifecycle, wait loop, and thread drain
- `load/test/run_state_test.rb` — focused tests for state mutation and persistence
- `load/test/invariant_monitor_test.rb` — focused tests for monitor policy behavior
- `load/test/load_execution_test.rb` — focused tests for worker/reporter execution behavior

**Modify:**
- `load/lib/load.rb` — require the new classes
- `load/lib/load/runner.rb` — slim down to high-level orchestration using the new collaborators
- `load/test/runner_test.rb` — keep behavior-anchoring tests, update only where collaborators become explicit seams
- `load/test/test_helper.rb` — add any tiny shared fakes/helpers needed by the new focused test files

**Verify against unchanged behavior:**
- `load/test/cli_test.rb`
- `load/test/fixture_verifier_test.rb`
- `workloads/missing_index_todos/test/oracle_test.rb`
- `workloads/missing_index_todos/test/workload_test.rb`

---

### Task 1: Extract `RunState`

**Files:**
- Create: `load/lib/load/run_state.rb`
- Modify: `load/lib/load.rb`, `load/lib/load/runner.rb`
- Test: `load/test/run_state_test.rb`, `load/test/runner_test.rb`

- [ ] **Step 1: Write the failing `RunState` tests**

```ruby
# load/test/run_state_test.rb
# ABOUTME: Verifies run-state mutation and persistence for load runs.
# ABOUTME: Covers initial payload shape, window pinning, warnings, samples, and final outcome.
require_relative "test_helper"

class RunStateTest < Minitest::Test
  def test_initial_write_matches_runner_contract
    run_record = FakeRunRecord.new
    workload = build_workload
    state = Load::RunState.new(
      run_record:,
      workload:,
      adapter_bin: "adapters/rails/bin/bench-adapter",
      app_root: "/tmp/demo",
      readiness_path: "/up",
      startup_grace_seconds: 15.0,
      metrics_interval_seconds: 5.0,
      workload_file: "workloads/missing_index_todos/workload",
    )

    state.write_initial

    payload = run_record.read_run_json
    assert_equal workload.name, payload.dig("workload", "name")
    assert_equal "/up", payload.dig("window", "readiness", "path")
    assert_equal [], payload.fetch("warnings")
    assert_equal [], payload.fetch("invariant_samples")
  end

  def test_pin_window_start_only_writes_once
    run_record = FakeRunRecord.new
    state = build_state(run_record:)

    state.write_initial
    state.pin_window_start(now: Time.utc(2026, 4, 25, 12, 0, 0))
    state.pin_window_start(now: Time.utc(2026, 4, 25, 12, 5, 0))

    assert_equal "2026-04-25 12:00:00 UTC", run_record.read_run_json.dig("window", "start_ts")
  end

  def test_append_warning_and_sample_persist_into_run_json
    run_record = FakeRunRecord.new
    state = build_state(run_record:)

    state.write_initial
    state.append_warning(type: "invariant_breach", message: "too low")
    state.append_invariant_sample(sampled_at: "2026-04-25 12:00:00 UTC", breach: true, breaches: ["too low"], checks: [])

    payload = run_record.read_run_json
    assert_equal 1, payload.fetch("warnings").length
    assert_equal 1, payload.fetch("invariant_samples").length
  end

  def test_finish_writes_request_totals_and_error_code
    run_record = FakeRunRecord.new
    state = build_state(run_record:)

    state.write_initial
    state.finish(
      now: Time.utc(2026, 4, 25, 12, 1, 0),
      request_totals: { total: 10, ok: 9, error: 1 },
      aborted: true,
      error_code: "adapter_error",
    )

    payload = run_record.read_run_json
    assert_equal 10, payload.dig("outcome", "requests_total")
    assert_equal "adapter_error", payload.dig("outcome", "error_code")
  end

  def test_snapshot_returns_an_isolated_copy
    state = build_state(run_record: FakeRunRecord.new)
    state.write_initial

    snapshot = state.snapshot
    snapshot["warnings"] << "mutation"

    assert_equal [], state.snapshot.fetch("warnings")
  end

  private

  def build_state(run_record:)
    Load::RunState.new(
      run_record:,
      workload: build_workload,
      adapter_bin: "adapters/rails/bin/bench-adapter",
      app_root: "/tmp/demo",
      readiness_path: "/up",
      startup_grace_seconds: 15.0,
      metrics_interval_seconds: 5.0,
      workload_file: "workloads/missing_index_todos/workload",
    )
  end

  def build_workload
    Class.new(Load::Workload) do
      def name = "fixture-workload"
      def scale = Load::Scale.new(rows_per_table: 1, seed: 42)
      def actions = []
      def load_plan = Load::LoadPlan.new(workers: 1, duration_seconds: 0, rate_limit: :unlimited, seed: 42)
    end.new
  end
end
```

- [ ] **Step 2: Run the focused test file and verify it fails**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/run_state_test.rb`

Expected: `NameError` or `LoadError` because `Load::RunState` does not exist yet.

- [ ] **Step 3: Implement `Load::RunState` with the current runner contract**

```ruby
# load/lib/load/run_state.rb
# ABOUTME: Owns the mutable run payload and persists it to the run record.
# ABOUTME: Encapsulates initial state, warnings, invariant samples, and final outcome shaping.
module Load
  class RunState
    def initialize(run_record:, workload:, adapter_bin:, app_root:, readiness_path:, startup_grace_seconds:, metrics_interval_seconds:, workload_file:)
      @run_record = run_record
      @mutex = Mutex.new
      @window_started = false
      @state = {
        run_id: File.basename(@run_record.run_dir),
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
        outcome: {
          requests_total: 0,
          requests_ok: 0,
          requests_error: 0,
          aborted: false,
        },
        query_ids: [],
        warnings: [],
        invariant_samples: [],
      }
    end

    def write_initial
      write_current
    end

    def merge(fragment)
      @mutex.synchronize do
        @state = deep_merge(@state, fragment)
        write_current
      end
    end

    def pin_window_start(now:)
      @mutex.synchronize do
        return if @window_started

        @window_started = true
        @state = deep_merge(@state, window: { start_ts: now })
        write_current
      end
    end

    def append_warning(payload)
      @mutex.synchronize do
        @state[:warnings] = @state.fetch(:warnings) + [payload]
        write_current
      end
    end

    def append_invariant_sample(payload)
      @mutex.synchronize do
        @state[:invariant_samples] = @state.fetch(:invariant_samples) + [payload]
        write_current
      end
    end

    def finish(now:, request_totals:, aborted:, error_code: nil)
      merge(
        window: { end_ts: now },
        outcome: {
          requests_total: request_totals.fetch(:total),
          requests_ok: request_totals.fetch(:ok),
          requests_error: request_totals.fetch(:error),
          aborted: aborted,
          error_code: error_code,
        }.compact,
      )
    end

    def snapshot
      @mutex.synchronize { deep_copy(@state) }
    end

    private

    def write_current
      @run_record.write_run(deep_copy(@state))
    end

    def deep_merge(left, right)
      merger = proc do |_key, old_value, new_value|
        if old_value.is_a?(Hash) && new_value.is_a?(Hash)
          old_value.merge(new_value, &merger)
        else
          new_value
        end
      end
      left.merge(right, &merger)
    end

    def deep_copy(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, child), copy| copy[key] = deep_copy(child) }
      when Array
        value.map { |child| deep_copy(child) }
      else
        value
      end
    end
  end
end
```

- [ ] **Step 4: Load the new class from the namespace entrypoint**

```ruby
# load/lib/load.rb
require_relative "load/run_state"
```

- [ ] **Step 5: Run the focused `RunState` tests and verify they pass**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/run_state_test.rb`

Expected: `4 runs, ... 0 failures, 0 errors`

- [ ] **Step 6: Move runner state persistence onto `RunState` without changing behavior**

```ruby
# load/lib/load/runner.rb
@run_state = Load::RunState.new(
  run_record: @run_record,
  workload: @workload,
  adapter_bin: @settings.adapter_bin || @adapter_client.adapter_bin,
  app_root: @settings.app_root,
  readiness_path: @settings.readiness_path,
  startup_grace_seconds: @settings.startup_grace_seconds,
  metrics_interval_seconds: @settings.metrics_interval_seconds,
  workload_file: workload_file,
)

@run_state.write_initial
@run_state.merge(adapter: { describe: adapter_describe, bin: ..., app_root: ... })
@run_state.merge(query_ids: Array(reset_state["query_ids"]).map(&:to_s)) if ...
@run_state.merge(adapter: { pid: ..., base_url: ... })
@run_state.merge(window: { readiness: readiness_payload })
```

Also replace:

```ruby
write_state(...)
snapshot_state
pin_window_start
append_warning
append_invariant_sample
outcome_payload
initial_state
```

with `RunState` calls.

Delete the runner-owned state machinery after replacement:

```ruby
@state
@state_mutex
@window_started
write_state
snapshot_state
initial_state
pin_window_start
append_warning
append_invariant_sample
outcome_payload
```

- [ ] **Step 7: Run the runner behavior locks**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb`

Expected: existing runner tests still green.

- [ ] **Step 8: Commit the `RunState` extraction**

```bash
git add load/lib/load.rb load/lib/load/run_state.rb load/lib/load/runner.rb load/test/run_state_test.rb load/test/runner_test.rb
git commit -m "refactor: extract run state"
```

---

### Task 2: Extract `InvariantMonitor`

**Files:**
- Create: `load/lib/load/invariant_monitor.rb`
- Modify: `load/lib/load.rb`, `load/lib/load/runner.rb`
- Test: `load/test/invariant_monitor_test.rb`, `load/test/runner_test.rb`

- [ ] **Step 1: Write focused monitor tests for `enforce|warn|off` and thread lifecycle**

```ruby
# load/test/invariant_monitor_test.rb
# ABOUTME: Verifies invariant monitor thread lifecycle and policy handling.
# ABOUTME: Covers enforce, warn, off, shutdown, and failure propagation.
require_relative "test_helper"

class InvariantMonitorTest < Minitest::Test
  def test_warn_policy_records_warning_without_triggering_stop
    warnings = []
    stops = []
    monitor = Load::InvariantMonitor.new(
      sampler: -> { sample(breach: true) },
      policy: :warn,
      interval_seconds: 0.0,
      stop_flag: Load::Runner::InternalStopFlag.new,
      sleeper: ->(*) {},
      on_sample: ->(*) {},
      on_warning: ->(payload) { warnings << payload },
      on_breach_stop: ->(reason) { stops << reason },
      stderr: StringIO.new,
    )

    monitor.sample_once

    assert_equal 1, warnings.length
    assert_equal [], stops
  end

  def test_enforce_policy_triggers_stop_after_three_consecutive_breaches
    stops = []
    monitor = Load::InvariantMonitor.new(
      sampler: -> { sample(breach: true) },
      policy: :enforce,
      interval_seconds: 0.0,
      stop_flag: Load::Runner::InternalStopFlag.new,
      sleeper: ->(*) {},
      on_sample: ->(*) {},
      on_warning: ->(*) {},
      on_breach_stop: ->(reason) { stops << reason },
      stderr: StringIO.new,
    )

    3.times { monitor.sample_once }

    assert_equal [:invariant_breach], stops
  end

  def test_off_policy_never_starts
    monitor = Load::InvariantMonitor.new(
      sampler: -> { flunk "should not sample" },
      policy: :off,
      interval_seconds: 0.0,
      stop_flag: Load::Runner::InternalStopFlag.new,
      sleeper: ->(*) {},
      on_sample: ->(*) {},
      on_warning: ->(*) {},
      on_breach_stop: ->(*) {},
      stderr: StringIO.new,
    )

    assert_nil monitor.start
  end

  def test_monitor_stop_unblocks_thread_during_sleep
    blocker = Queue.new
    sleep_observed = Queue.new
    monitor = Load::InvariantMonitor.new(
      sampler: -> { sample(breach: false) },
      policy: :enforce,
      interval_seconds: 60.0,
      stop_flag: Load::Runner::InternalStopFlag.new,
      sleeper: ->(*) { sleep_observed << true; blocker.pop },
      on_sample: ->(*) {},
      on_warning: ->(*) {},
      on_breach_stop: ->(*) {},
      stderr: StringIO.new,
    )

    thread = monitor.start
    sleep_observed.pop
    monitor.stop(thread)

    refute thread.alive?
  end

  def test_monitor_propagates_sampler_failure_as_breach_stop
    stops = []
    monitor = Load::InvariantMonitor.new(
      sampler: -> { raise "boom" },
      policy: :enforce,
      interval_seconds: 0.0,
      stop_flag: Load::Runner::InternalStopFlag.new,
      sleeper: ->(*) {},
      on_sample: ->(*) {},
      on_warning: ->(*) {},
      on_breach_stop: ->(reason) { stops << reason },
      stderr: StringIO.new,
    )

    thread = monitor.start
    thread.join

    assert_equal [:invariant_sampler_failed], stops
    assert_raises(Load::InvariantMonitor::Failure) { monitor.stop(thread) }
  end

  private

  def sample(breach:)
    Load::Runner::InvariantSample.new(
      [Load::Runner::InvariantCheck.new("open_count", breach ? 1 : 10, 5, nil)]
    )
  end
end
```

- [ ] **Step 2: Run the focused monitor tests and verify they fail**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/invariant_monitor_test.rb`

Expected: `NameError` or `LoadError` because `Load::InvariantMonitor` does not exist yet.

- [ ] **Step 3: Implement `InvariantMonitor` as the owner of the sampling thread**

```ruby
# load/lib/load/invariant_monitor.rb
# ABOUTME: Runs the invariant sampler thread and applies breach policy.
# ABOUTME: Emits samples, warnings, and stop signals without owning run-record schema.
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
    end

    def start
      return nil if @policy == :off || @sampler.nil?

      Thread.new do
        begin
          loop do
            break if @stop_flag.call

            begin
              Thread.handle_interrupt(Shutdown => :immediate) do
                sleep_once
              end
            rescue Shutdown
              break
            end

            break if @stop_flag.call

            Thread.handle_interrupt(Shutdown => :never) do
              sample_once
            end
          end
        rescue StopIteration, Shutdown
          nil
        rescue StandardError => error
          @failure ||= error
          @on_breach_stop.call(:invariant_sampler_failed)
        end
      end
    end

    def stop(thread)
      return unless thread

      if @sleeping
        thread.raise(Shutdown.new)
      end
      thread.join
      failure = @failure
      @failure = nil
      raise Failure, "invariant sampler failed" if failure
    rescue ThreadError
      failure = @failure
      @failure = nil
      raise Failure, "invariant sampler failed" if failure
    end

    def sample_once
      sample = @sampler.call
      @on_sample.call(sample)
      return reset_breaches unless sample.breach?

      warning = sample.to_warning
      @on_warning.call(warning)
      if @policy == :warn
        @stderr.puts("warning: invariant breach: #{sample.breaches.join('; ')}")
        return
      end

      @consecutive_breaches += 1
      @on_breach_stop.call(:invariant_breach) if @consecutive_breaches >= 3
    end

    private

    def sleep_once
      @sleeping = true
      @sleeper.call(@interval_seconds)
    ensure
      @sleeping = false
    end

    def reset_breaches
      @consecutive_breaches = 0 if @policy == :enforce
    end
  end
end
```

- [ ] **Step 4: Require the new class from `load/lib/load.rb`**

```ruby
# load/lib/load.rb
require_relative "load/invariant_monitor"
```

- [ ] **Step 5: Replace the monitor loop inside `Runner` with the new object**

```ruby
# load/lib/load/runner.rb
@invariant_monitor = Load::InvariantMonitor.new(
  sampler: sampler,
  policy: invariant_policy,
  interval_seconds: invariant_sample_interval_seconds,
  stop_flag: @runtime.stop_flag,
  sleeper: @runtime.sleeper,
  on_sample: ->(sample) { @run_state.append_invariant_sample(sample.to_record(sampled_at: current_time)) },
  on_warning: ->(warning) { @run_state.append_warning(warning) },
  on_breach_stop: ->(reason) { trigger_stop(reason) },
  stderr: @stderr,
)
```

Then replace:

```ruby
start_invariant_thread
stop_invariant_thread
sample_invariants
reset_invariant_breaches
emit_invariant_warning
mark_invariant_thread_sleeping
invariant_thread_sleeping?
record_invariant_failure
raise_invariant_failure_if_present
```

with the monitor’s public `start` and `stop`.

Delete the runner-owned invariant scaffolding after replacement:

```ruby
InvariantState
@invariants
start_invariant_thread
stop_invariant_thread
sample_invariants
reset_invariant_breaches
emit_invariant_warning
mark_invariant_thread_sleeping
invariant_thread_sleeping?
record_invariant_failure
raise_invariant_failure_if_present
```

- [ ] **Step 6: Run the monitor-focused tests**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/invariant_monitor_test.rb`

Expected: `3 runs, ... 0 failures, 0 errors`

- [ ] **Step 7: Run the existing runner invariant-policy tests unchanged**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb`

Expected: the existing behavior locks remain green unchanged:

```text
test_runner_aborts_after_three_consecutive_invariant_breaches
test_runner_warn_policy_records_breaches_without_aborting
test_runner_off_policy_skips_invariant_sampling
test_runner_records_invariant_breach_before_first_successful_request
test_runner_persists_invariant_samples_in_run_record
test_internal_stop_flag_preserves_first_reason
```

- [ ] **Step 8: Commit the `InvariantMonitor` extraction**

```bash
git add load/lib/load.rb load/lib/load/invariant_monitor.rb load/lib/load/runner.rb load/test/invariant_monitor_test.rb load/test/runner_test.rb
git commit -m "refactor: extract invariant monitor"
```

---

### Task 3: Extract `LoadExecution`

**Files:**
- Create: `load/lib/load/load_execution.rb`
- Modify: `load/lib/load.rb`, `load/lib/load/runner.rb`
- Test: `load/test/load_execution_test.rb`, `load/test/runner_test.rb`

- [ ] **Step 1: Write focused execution tests for worker/reporter behavior without racy exact counts**

```ruby
# load/test/load_execution_test.rb
# ABOUTME: Verifies worker construction, reporter lifecycle, and request-total aggregation.
# ABOUTME: Covers finite execution, continuous execution, and bounded thread drain.
require_relative "test_helper"

class LoadExecutionTest < Minitest::Test
  def test_returns_request_totals_with_at_least_one_success
    ready = Queue.new
    release = Queue.new
    stop_flag = Load::Runner::InternalStopFlag.new
    execution = Load::LoadExecution.new(
      workload: build_workload(action_class: BarrierAction, workers: 1, duration_seconds: 60.0),
      base_url: "http://127.0.0.1:3000",
      runtime: runtime(stop_flag:),
      metrics_interval_seconds: 5.0,
      run_record: FakeRunRecord.new,
      on_first_success: -> {},
      reporter_factory: ->(**) { FakeReporter.new },
    )
    BarrierAction.ready_queue = ready
    BarrierAction.release_queue = release

    thread = Thread.new { execution.run(mode: :finite, duration_seconds: 60.0) }
    ready.pop
    stop_flag.trigger(:timeout)
    release << true
    result = thread.value

    assert_operator result.fetch(:ok), :>=, 1
  end

  def test_continuous_mode_waits_for_stop_flag
    stop_flag = Load::Runner::InternalStopFlag.new
    execution = Load::LoadExecution.new(
      workload: build_workload(action_class: FastAction, workers: 1, duration_seconds: 60.0),
      base_url: "http://127.0.0.1:3000",
      runtime: Load::Runner::Runtime.new(-> { Time.now.utc }, ->(*) { stop_flag.trigger(:sigterm) }, FakeHttp.new, stop_flag),
      metrics_interval_seconds: 5.0,
      run_record: FakeRunRecord.new,
      on_first_success: -> {},
      reporter_factory: ->(**) { FakeReporter.new },
    )

    result = execution.run(mode: :continuous, duration_seconds: 60.0)

    assert_operator result.fetch(:ok), :>=, 1
  end

  def test_on_first_success_fires_once_across_concurrent_workers
    mutex = Mutex.new
    calls = []
    execution = Load::LoadExecution.new(
      workload: build_workload(action_class: FastAction, workers: 16, duration_seconds: 0.01),
      base_url: "http://127.0.0.1:3000",
      runtime: runtime,
      metrics_interval_seconds: 5.0,
      run_record: FakeRunRecord.new,
      on_first_success: -> { mutex.synchronize { calls << true } },
      reporter_factory: ->(**) { FakeReporter.new },
    )

    execution.run(mode: :finite, duration_seconds: 0.01)

    assert_equal 1, calls.length
  end

  def test_reporter_stops_when_wait_raises
    reporter = FakeReporter.new
    execution = Load::LoadExecution.new(
      workload: build_workload(action_class: FastAction, workers: 1, duration_seconds: 60.0),
      base_url: "http://127.0.0.1:3000",
      runtime: Load::Runner::Runtime.new(-> { Time.now.utc }, ->(*) { raise "boom" }, FakeHttp.new, Load::Runner::InternalStopFlag.new),
      metrics_interval_seconds: 5.0,
      run_record: FakeRunRecord.new,
      on_first_success: -> {},
      reporter_factory: ->(**) { reporter },
    )

    assert_raises(RuntimeError) { execution.run(mode: :finite, duration_seconds: 60.0) }
    assert_equal 1, reporter.stop_calls
  end

  private

  def build_workload(action_class:, workers:, duration_seconds:)
    Class.new(Load::Workload) do
      def name = "fixture-workload"
      def scale = Load::Scale.new(rows_per_table: 1, seed: 42)
      define_method(:actions) { [Load::ActionEntry.new(action_class, 1)] }
      define_method(:load_plan) { Load::LoadPlan.new(workers:, duration_seconds:, rate_limit: :unlimited, seed: 42) }
    end.new
  end

  FastAction = Class.new(Load::Action) do
    Response = Struct.new(:code)
    def name = :fast
    def call = Response.new("200")
  end

  BarrierAction = Class.new(Load::Action) do
    Response = Struct.new(:code)

    class << self
      attr_accessor :ready_queue, :release_queue
    end

    def name = :barrier

    def call
      self.class.ready_queue << true
      self.class.release_queue.pop
      Response.new("200")
    end
  end

  class FakeReporter
    attr_reader :stop_calls

    def initialize
      @stop_calls = 0
    end

    def start; end

    def stop
      @stop_calls += 1
    end
  end

  def runtime(stop_flag: Load::Runner::InternalStopFlag.new)
    Load::Runner::Runtime.new(-> { Time.now.utc }, ->(*) {}, FakeHttp.new, stop_flag)
  end
end
```

- [ ] **Step 2: Run the focused execution tests and verify they fail**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/load_execution_test.rb`

Expected: `NameError` or `LoadError` because `Load::LoadExecution` does not exist yet.

- [ ] **Step 3: Implement `LoadExecution` as the owner of active worker-side execution**

```ruby
# load/lib/load/load_execution.rb
# ABOUTME: Runs workload traffic through workers and reporters for one load window.
# ABOUTME: Owns worker construction, wait-loop behavior, request totals, and thread drain.
module Load
  class LoadExecution
    WORKER_DRAIN_TIMEOUT_SECONDS = 1.0
    CONTINUOUS_POLL_SECONDS = 0.1

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

    def initialize(workload:, base_url:, runtime:, metrics_interval_seconds:, run_record:, on_first_success:, reporter_factory: nil)
      @workload = workload
      @base_url = base_url
      @runtime = runtime
      @metrics_interval_seconds = metrics_interval_seconds
      @run_record = run_record
      @on_first_success = on_first_success
      @reporter_factory = reporter_factory
    end

    def run(mode:, duration_seconds:)
      workers = build_workers
      reporter = build_reporter(workers)
      reporter.start
      threads = workers.map { |worker| Thread.new { worker.run } }
      wait(mode:, duration_seconds:)
      drain_threads(threads)
      aggregate_request_totals(workers)
    ensure
      reporter&.stop
    end

    private

    def build_workers
      plan = @workload.load_plan
      entries = @workload.actions
      seed = plan.seed.nil? ? @workload.scale.seed : plan.seed
      rate_limiter = Load::RateLimiter.new(rate_limit: plan.rate_limit, clock: @runtime.clock, sleeper: @runtime.sleeper)

      Array.new(plan.workers) do |index|
        Load::Worker.new(
          worker_id: index + 1,
          selector: Load::Selector.new(entries: entries, rng: Random.new(seed + index)),
          buffer: TrackingBuffer.new(on_first_success: @on_first_success),
          client: Load::Client.new(base_url: @base_url, http: @runtime.http),
          ctx: { base_url: @base_url, scale: @workload.scale },
          rng: Random.new(seed + index),
          rate_limiter: rate_limiter,
          stop_flag: @runtime.stop_flag,
        )
      end
    end

    def build_reporter(workers)
      return @reporter_factory.call(workers:, interval_seconds: @metrics_interval_seconds, run_record: @run_record, runtime: @runtime) if @reporter_factory

      Load::Reporter.new(
        workers:,
        interval_seconds: @metrics_interval_seconds,
        sink: Load::Runner::MetricsSink.new(@run_record),
        clock: @runtime.clock,
        sleeper: @runtime.sleeper,
      )
    end

    def wait(mode:, duration_seconds:)
      if mode == :continuous
        until @runtime.stop_flag.call
          Thread.pass
          @runtime.sleeper.call(CONTINUOUS_POLL_SECONDS)
        end
      else
        deadline = @runtime.clock.call + duration_seconds
        until @runtime.stop_flag.call
          remaining = deadline - @runtime.clock.call
          if remaining <= 0
            @runtime.stop_flag.trigger(:timeout) if @runtime.stop_flag.respond_to?(:trigger)
            break
          end
          Thread.pass
          @runtime.sleeper.call([1.0, remaining].min)
        end
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
      workers.reduce({ total: 0, ok: 0, error: 0 }) do |totals, worker|
        buffer_totals = worker.buffer.request_totals
        {
          total: totals[:total] + buffer_totals[:total],
          ok: totals[:ok] + buffer_totals[:ok],
          error: totals[:error] + buffer_totals[:error],
        }
      end
    end
  end
end
```

- [ ] **Step 4: Load the new class from `load/lib/load.rb`**

```ruby
# load/lib/load.rb
require_relative "load/load_execution"
```

- [ ] **Step 5: Replace worker/reporter execution inside `Runner`**

```ruby
# load/lib/load/runner.rb
execution = Load::LoadExecution.new(
  workload: @workload,
  base_url: start_response.fetch("base_url"),
  runtime: @runtime,
  metrics_interval_seconds: @settings.metrics_interval_seconds,
  run_record: @run_record,
  on_first_success: -> { @run_state.pin_window_start(now: current_time) },
)
request_totals = execution.run(mode: @mode, duration_seconds: @workload.load_plan.duration_seconds)
```

Then let `Runner` use `request_totals` when finalizing the outcome through `RunState`.

Delete the runner-owned worker execution scaffolding after replacement:

```ruby
TrackingBuffer
@tracking_buffers
register_tracking_buffer
aggregate_request_totals
start_workers
wait_for_window_end
wait_for_stop_signal
```

- [ ] **Step 6: Run the focused execution tests**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/load_execution_test.rb`

Expected: `4 runs, ... 0 failures, 0 errors`

- [ ] **Step 7: Run the runner behavior suite again**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb`

Expected: all existing runner tests remain green, especially:

```text
test_runner_aborts_after_three_consecutive_invariant_breaches
test_runner_warn_policy_records_breaches_without_aborting
test_runner_off_policy_skips_invariant_sampling
test_runner_records_invariant_breach_before_first_successful_request
test_runner_persists_invariant_samples_in_run_record
test_internal_stop_flag_preserves_first_reason
```

- [ ] **Step 8: Commit the `LoadExecution` extraction**

```bash
git add load/lib/load.rb load/lib/load/load_execution.rb load/lib/load/runner.rb load/test/load_execution_test.rb load/test/runner_test.rb
git commit -m "refactor: extract load execution"
```

---

### Task 4: Regression Verification and Cleanup

**Files:**
- Modify: `load/lib/load/runner.rb` (only if tiny cleanup is still needed)
- Test: `load/test/cli_test.rb`, `load/test/fixture_verifier_test.rb`, `workloads/missing_index_todos/test/oracle_test.rb`, `workloads/missing_index_todos/test/workload_test.rb`

- [ ] **Step 1: Run the full load suite**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby -e 'Dir["load/test/*_test.rb"].sort.each { |path| load path }'`

Expected: full suite passes with `0 failures, 0 errors`.

- [ ] **Step 2: Run the workload suite**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby -e 'Dir["workloads/missing_index_todos/test/*_test.rb"].sort.each { |path| load path }'`

Expected: workload tests pass with `0 failures, 0 errors`.

- [ ] **Step 3: Run the adapter suite**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby -e 'Dir["adapters/rails/test/*_test.rb"].sort.each { |path| load path }'`

Expected: adapter tests pass with the existing opt-in skips only.

- [ ] **Step 4: Run whitespace and staged-diff hygiene checks**

Run: `git diff --check`

Expected: no output

Then run the runner-cleanup grep:

Run:

```bash
grep -n "@state\\|@state_mutex\\|@window_started\\|@tracking_buffers\\|register_tracking_buffer\\|aggregate_request_totals\\|InvariantState\\|TrackingBuffer\\|wait_for_window_end\\|wait_for_stop_signal\\|start_invariant_thread\\|stop_invariant_thread\\|sample_invariants\\|emit_invariant_warning\\|mark_invariant_thread_sleeping\\|invariant_thread_sleeping" load/lib/load/runner.rb
```

Expected: no output

- [ ] **Step 5: Commit the verified refactor**

```bash
git add load/lib/load/runner.rb load/test/cli_test.rb load/test/fixture_verifier_test.rb workloads/missing_index_todos/test/oracle_test.rb workloads/missing_index_todos/test/workload_test.rb
git commit -m "test: verify runner decomposition"
```

---

## Self-Review

### Spec Coverage

- `RunState` extraction: covered by Task 1
- `InvariantMonitor` extraction: covered by Task 2
- `LoadExecution` extraction: covered by Task 3
- keep `Runner` as top-level coordinator: covered by Tasks 1-3 by only moving internals
- preserve CLI, artifact shape, and invariant semantics: covered by Task 4 plus unchanged runner/CLI/workload tests
- preserve `:timeout` stop-flag trigger on finite deadline: covered by Task 3 step 3 and runner regression tests
- preserve cooperative shutdown of the invariant thread (`Thread.handle_interrupt` scoping): covered by Task 2 step 3 and the new lifecycle test
- monitor failure propagates as `:invariant_sampler_failed`: covered by Task 2 step 1 and step 3
- tracking buffer is a real named class, not an anonymous per-worker class: covered by Task 3 step 3

No spec gaps found.

### Placeholder Scan

- No `TODO`, `TBD`, or “implement later” placeholders remain.
- Each code-changing step contains concrete file paths, commands, and code sketches.

### Type Consistency

- `RunState` API uses `write_initial`, `merge`, `pin_window_start`, `append_warning`, `append_invariant_sample`, and `finish` consistently.
- `InvariantMonitor` API uses `start`, `stop`, and `sample_once` consistently.
- `LoadExecution` API uses `run(mode:, duration_seconds:)` and returns the request-totals hash directly.

Plan is internally consistent.

## Validation Gate

- `make test` must pass cleanly.
- 50x stability gate on the relocated invariant-breach runner test:

```bash
for i in $(seq 1 50); do
  BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb \
    --name test_runner_aborts_after_three_consecutive_invariant_breaches 2>&1 | tail -3
done | grep -E "errors|failures" | sort -u
```

Expected: one line reporting `0 failures, 0 errors`.

- 50x stability gate on cooperative monitor shutdown:

```bash
for i in $(seq 1 50); do
  BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/invariant_monitor_test.rb \
    --name test_monitor_stop_unblocks_thread_during_sleep 2>&1 | tail -3
done | grep -E "errors|failures" | sort -u
```

Expected: one line reporting `0 failures, 0 errors`.

- Live finite run plus oracle:

```bash
DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo \
BENCH_ADAPTER_PG_ADMIN_URL=postgres://postgres:postgres@localhost:5432/postgres \
BUNDLE_GEMFILE=collector/Gemfile \
bundle exec bin/load run \
  --workload missing-index-todos \
  --adapter adapters/rails/bin/bench-adapter \
  --app-root /home/bjw/db-specialist-demo

DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo \
CLICKHOUSE_URL=http://localhost:8123/ \
BUNDLE_GEMFILE=collector/Gemfile \
bundle exec ruby workloads/missing_index_todos/oracle.rb runs/<latest>
```

Expected: oracle prints `PASS`.

- Runner cleanup grep from Task 4 step 4 returns no output.
- `wc -l load/lib/load/runner.rb` should drop substantially from the current ~600-line shape toward roughly 250-300 lines.
