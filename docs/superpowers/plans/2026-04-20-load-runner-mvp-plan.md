# Load Runner MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the fixture harness with a generic Ruby load runner, a narrow Rails adapter, and one `missing-index-todos` workload that reproduces the seq-scan pathology through normal app traffic.

**Architecture:** Keep the new runner isolated under `/load`, keep all app lifecycle and database work behind `adapters/rails/bin/bench-adapter`, and keep pathology-specific logic inside `workloads/missing_index_todos/`. Build the new path alongside the existing fixture harness until the replacement is fully green, then delete the old harness in one cleanup slice so the branch never goes red.

**Tech Stack:** Ruby 3.3 stdlib (`json`, `open3`, `net/http`, `optparse`, `time`, `uri`, `socket`), `minitest`, `pg`, Docker Compose, external Rails app at `/home/bjw/db-specialist-demo`.

---

## File Map

### Create

- `load/lib/load.rb`
- `load/lib/load/action.rb`
- `load/lib/load/action_entry.rb`
- `load/lib/load/adapter_client.rb`
- `load/lib/load/client.rb`
- `load/lib/load/load_plan.rb`
- `load/lib/load/metrics.rb`
- `load/lib/load/rate_limiter.rb`
- `load/lib/load/reporter.rb`
- `load/lib/load/run_record.rb`
- `load/lib/load/runner.rb`
- `load/lib/load/scale.rb`
- `load/lib/load/selector.rb`
- `load/lib/load/worker.rb`
- `load/lib/load/workload.rb`
- `load/test/test_helper.rb`
- `load/test/rate_limiter_test.rb`
- `load/test/selector_test.rb`
- `load/test/metrics_test.rb`
- `load/test/reporter_test.rb`
- `load/test/adapter_client_test.rb`
- `load/test/run_record_test.rb`
- `load/test/runner_test.rb`
- `load/test/worker_test.rb`
- `load/test/cli_test.rb`
- `load/test/load_smoke_target_test.rb`
- `adapters/rails/bin/bench-adapter`
- `adapters/rails/lib/rails_adapter.rb`
- `adapters/rails/lib/rails_adapter/result.rb`
- `adapters/rails/lib/rails_adapter/command_runner.rb`
- `adapters/rails/lib/rails_adapter/port_finder.rb`
- `adapters/rails/lib/rails_adapter/template_cache.rb`
- `adapters/rails/lib/rails_adapter/commands/describe.rb`
- `adapters/rails/lib/rails_adapter/commands/prepare.rb`
- `adapters/rails/lib/rails_adapter/commands/migrate.rb`
- `adapters/rails/lib/rails_adapter/commands/load_dataset.rb`
- `adapters/rails/lib/rails_adapter/commands/reset_state.rb`
- `adapters/rails/lib/rails_adapter/commands/start.rb`
- `adapters/rails/lib/rails_adapter/commands/stop.rb`
- `adapters/rails/test/test_helper.rb`
- `adapters/rails/test/describe_test.rb`
- `adapters/rails/test/prepare_test.rb`
- `adapters/rails/test/migrate_test.rb`
- `adapters/rails/test/load_dataset_test.rb`
- `adapters/rails/test/reset_state_test.rb`
- `adapters/rails/test/start_test.rb`
- `adapters/rails/test/stop_test.rb`
- `adapters/rails/test/integration_test.rb`
- `adapters/rails/test/fixtures/demo_app/` with the minimal Rails fixture files required by `bin/rails`
- `adapters/rails/README.md`
- `workloads/missing_index_todos/workload.rb`
- `workloads/missing_index_todos/actions/list_open_todos.rb`
- `workloads/missing_index_todos/oracle.rb`
- `workloads/missing_index_todos/README.md`
- `workloads/missing_index_todos/test/workload_test.rb`
- `workloads/missing_index_todos/test/oracle_test.rb`
- `bin/load`

### Modify

- `README.md`
- `Makefile`
- `.gitignore`
- `JOURNAL.md`
- `/home/bjw/db-specialist-demo/config/database.yml` (cross-repo dependency)
- `/home/bjw/db-specialist-demo/db/seeds.rb` (cross-repo dependency)

### Delete

- `bin/fixture`
- `collector/lib/fixtures/command.rb`
- `collector/lib/fixtures/manifest.rb`
- `collector/test/fixtures/fixture_command_test.rb`
- `collector/test/fixtures/fixture_manifest_test.rb`
- `collector/test/fixtures/fixture_smoke_target_test.rb`
- `collector/test/fixtures/missing_index_assert_test.rb`
- `collector/test/fixtures/missing_index_drive_test.rb`
- `collector/test/fixtures/missing_index_reset_test.rb`
- `fixtures/missing-index/README.md`
- `fixtures/missing-index/load/drive.rb`
- `fixtures/missing-index/manifest.yml`
- `fixtures/missing-index/setup/01_schema.sql`
- `fixtures/missing-index/setup/02_seed.sql`
- `fixtures/missing-index/setup/reset.rb`
- `fixtures/missing-index/validate/assert.rb`
- `load/harness.rb`
- `load/test/harness_test.rb`
- `load/README.md`
- `fixture-harness-walkthrough.md`

## Cross-Repo Dependency

The checkpoint-collector implementation depends on a small but real change in `/home/bjw/db-specialist-demo`:

- add `benchmark:` to `config/database.yml`
- replace the toy `db/seeds.rb` with the parameterized Postgres seed that reads `SEED`, `ROWS_PER_TABLE`, and `OPEN_FRACTION`

That work stays in the external repo and should land before the final parity verification. The current schema in `db/schema.rb` already matches the missing-index requirement: `todos.status` has no index and `todos.user_id` does.

### Task 1: Runner Foundations

**Files:**
- Create: `load/lib/load.rb`
- Create: `load/lib/load/action.rb`
- Create: `load/lib/load/action_entry.rb`
- Create: `load/lib/load/load_plan.rb`
- Create: `load/lib/load/rate_limiter.rb`
- Create: `load/lib/load/scale.rb`
- Create: `load/lib/load/selector.rb`
- Create: `load/lib/load/workload.rb`
- Create: `load/test/test_helper.rb`
- Create: `load/test/rate_limiter_test.rb`
- Create: `load/test/selector_test.rb`

- [ ] **Step 1: Write the failing rate limiter and selector tests**

```ruby
# load/test/rate_limiter_test.rb
def test_unlimited_rate_never_sleeps
  limiter = Load::RateLimiter.new(rate_limit: :unlimited, clock: -> { 10.0 }, sleeper: ->(*) { flunk("unexpected sleep") })

  limiter.wait_turn
end

def test_finite_rate_spaces_requests
  sleeps = []
  times = [0.0, 0.0, 0.2].each
  limiter = Load::RateLimiter.new(rate_limit: 5.0, clock: -> { times.next }, sleeper: ->(seconds) { sleeps << seconds })

  limiter.wait_turn
  limiter.wait_turn

  assert_in_delta 0.2, sleeps.first, 0.001
end

# load/test/selector_test.rb
def test_seeded_selector_is_repeatable
  entries = [
    Load::ActionEntry.new(AlphaAction, 1),
    Load::ActionEntry.new(BetaAction, 3),
  ]

  selector_a = Load::Selector.new(entries:, rng: Random.new(42))
  selector_b = Load::Selector.new(entries:, rng: Random.new(42))

  assert_equal 20.times.map { selector_a.next.action_class }, 20.times.map { selector_b.next.action_class }
end
```

- [ ] **Step 2: Run the new tests to confirm they fail**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/rate_limiter_test.rb`
Expected: `Load` constants are missing.

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/selector_test.rb`
Expected: `Load::Selector` is undefined.

- [ ] **Step 3: Implement value objects; port RateLimiter and Selector verbatim from existing fixture code**

**Value objects (new):**

```ruby
# load/lib/load/scale.rb
module Load
  Scale = Data.define(:rows_per_table, :open_fraction, :seed) do
    def initialize(rows_per_table:, open_fraction:, seed: 42)
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
```

**RateLimiter:** Do NOT reimplement. Copy the body of `Fixtures::MissingIndex::Drive::RateLimiter` from `fixtures/missing-index/load/drive.rb` verbatim into `load/lib/load/rate_limiter.rb`, renaming only the module (`Fixtures::MissingIndex::Drive` → `Load`). Preserve the exact mutex, clock/sleeper kwargs, and `:unlimited` branch. Behavior changes risk desynchronizing parity verification in Task 9 — port-then-verify is safer than port-and-improve. Port the existing rate-limiter tests alongside.

**Selector:** implement fresh (no existing code to port) — weighted random selection via the worker's seeded `Random`. Simplest correct implementation: cumulative-weight table built once in `initialize`, `Array#bsearch_index` against `rng.rand * total_weight` per call.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/rate_limiter_test.rb`
Expected: PASS

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/selector_test.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add load/lib/load.rb load/lib/load/action.rb load/lib/load/action_entry.rb load/lib/load/load_plan.rb load/lib/load/rate_limiter.rb load/lib/load/scale.rb load/lib/load/selector.rb load/lib/load/workload.rb load/test/test_helper.rb load/test/rate_limiter_test.rb load/test/selector_test.rb JOURNAL.md
git commit -m "feat: add load runner foundations"
```

### Task 2: Metrics, Worker Loop, and Run Record

**Files:**
- Create: `load/lib/load/client.rb`
- Create: `load/lib/load/metrics.rb`
- Create: `load/lib/load/reporter.rb`
- Create: `load/lib/load/run_record.rb`
- Create: `load/lib/load/worker.rb`
- Create: `load/test/metrics_test.rb`
- Create: `load/test/reporter_test.rb`
- Create: `load/test/run_record_test.rb`
- Create: `load/test/worker_test.rb`

- [ ] **Step 1: Write the failing metrics, reporter, and worker tests**

Per-worker buffer model (§8.6 of spec): every worker owns its own `Load::Metrics::Buffer`. The reporter iterates the worker list and swaps each buffer atomically; it never holds a single shared buffer.

```ruby
# load/test/metrics_test.rb
def test_snapshot_computes_percentiles_and_errors
  buffer = Load::Metrics::Buffer.new
  buffer.record_ok(action: :list_open_todos, latency_ns: 10_000_000, status: 200)
  buffer.record_ok(action: :list_open_todos, latency_ns: 30_000_000, status: 200)
  buffer.record_error(action: :list_open_todos, latency_ns: 50_000_000, error_class: "Net::ReadTimeout")

  snapshot = buffer.swap!

  stats = Load::Metrics::Snapshot.build(snapshot).fetch(:list_open_todos)
  assert_equal 3, stats.fetch(:count)
  assert_equal 1, stats.fetch(:error_count)
  assert_in_delta 30.0, stats.fetch(:p95_ms), 0.1
end

# load/test/reporter_test.rb
def test_reporter_merges_per_worker_buffers_at_each_interval
  workers = [FakeWorker.new, FakeWorker.new]
  workers[0].buffer.record_ok(action: :a, latency_ns: 5_000_000, status: 200)
  workers[1].buffer.record_ok(action: :a, latency_ns: 15_000_000, status: 200)
  sink = []
  clock = FakeClock.new([0.0, 5.0])
  reporter = Load::Reporter.new(workers:, interval_seconds: 5, sink:, clock:, sleeper: ->(*) {})

  reporter.snapshot_once  # simulate one tick

  line = sink.last
  assert_equal 2, line.fetch(:actions).fetch(:a).fetch(:count)
end

def test_reporter_emits_final_tail_snapshot_on_stop
  workers = [FakeWorker.new]
  sink = []
  reporter = Load::Reporter.new(workers:, interval_seconds: 5, sink:, clock: FakeClock.new, sleeper: ->(*) {})

  reporter.start
  # Record after the last periodic snapshot to simulate tail data.
  workers.first.buffer.record_ok(action: :a, latency_ns: 2_000_000, status: 200)
  reporter.stop  # must flush one more snapshot-merge-compute-append

  assert_equal 1, sink.sum { |line| line.fetch(:actions).fetch(:a, {}).fetch(:count, 0) }
end

# load/test/worker_test.rb
def test_worker_records_errors_without_raising
  selector = stub(next: Load::ActionEntry.new(FailingAction, 1))
  buffer = Load::Metrics::Buffer.new
  worker = Load::Worker.new(worker_id: 2, selector:, buffer:, client: Object.new, ctx: { base_url: "http://127.0.0.1:3000" }, rng: Random.new(7), rate_limiter: stub(wait_turn: nil), stop_flag: stop_after(1))

  worker.run

  assert_equal 1, buffer.swap!.fetch(:failing_action).fetch(:errors_by_class).fetch("RuntimeError")
end

def test_worker_records_error_when_selector_raises_before_started_ns
  # Regression: if `selector.next` raises, the old worker body left `started_ns`
  # unassigned and the rescue clause raised NameError. Guard against that.
  raising_selector = Object.new
  def raising_selector.next = raise RuntimeError, "boom"
  buffer = Load::Metrics::Buffer.new
  worker = Load::Worker.new(worker_id: 9, selector: raising_selector, buffer:, client: Object.new, ctx: {}, rng: Random.new(7), rate_limiter: stub(wait_turn: nil), stop_flag: stop_after(1))

  worker.run  # must NOT raise NameError

  bucket = buffer.swap!.fetch(:unknown)
  assert_equal 1, bucket.fetch(:errors_by_class).fetch("RuntimeError")
  assert_equal 0, bucket.fetch(:latencies_ns).first  # latency_ns recorded as 0 when no request actually started
end

def test_worker_records_error_when_action_init_raises
  # Same regression shape: action_class.new may raise on bad kwargs.
  bad_action_class = Class.new(Load::Action) do
    def initialize(**) = raise ArgumentError, "bad kwargs"
  end
  selector = stub(next: Load::ActionEntry.new(bad_action_class, 1))
  buffer = Load::Metrics::Buffer.new
  worker = Load::Worker.new(worker_id: 1, selector:, buffer:, client: Object.new, ctx: {}, rng: Random.new(7), rate_limiter: stub(wait_turn: nil), stop_flag: stop_after(1))

  worker.run

  assert_equal 1, buffer.swap!.fetch(:unknown).fetch(:errors_by_class).fetch("ArgumentError")
end
```

- [ ] **Step 2: Run the focused tests to verify they fail**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/metrics_test.rb`
Expected: `Load::Metrics` is undefined.

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/worker_test.rb`
Expected: `Load::Worker` is undefined.

- [ ] **Step 3: Implement the in-memory metrics types, the reporter, and the worker loop**

```ruby
# load/lib/load/metrics.rb
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
        @mutex.synchronize { current = @data; @data = fresh_data; current }
      end
    end
  end
end

# load/lib/load/worker.rb
module Load
  class Worker
    def run
      until @stop_flag.call
        # started_ns MUST be assigned before anything that can raise, so the rescue
        # clause always has a valid value. Prior shape assigned it after selector.next
        # and action_class.new — both of which can raise — producing NameError in the
        # rescue. Guarded by regression tests in worker_test.rb.
        started_ns = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
        action = nil
        begin
          @rate_limiter.wait_turn
          entry = @selector.next
          action = entry.action_class.new(rng: @rng, ctx: @ctx, client: @client)
          request_started_ns = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
          response = action.call
          @buffer.record_ok(action: action.name, latency_ns: elapsed_ns(request_started_ns), status: response.code.to_i)
        rescue StandardError => error
          # If the error happened before the request actually started, report latency 0
          # rather than the time spent selecting/constructing — that would contaminate
          # percentile data with selector overhead.
          latency_ns = defined?(request_started_ns) ? elapsed_ns(request_started_ns) : 0
          @buffer.record_error(action: (action && action.respond_to?(:name) ? action.name : :unknown), latency_ns:, error_class: error.class.name)
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the metrics, reporter, run-record, and worker tests**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/metrics_test.rb`
Expected: PASS

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/reporter_test.rb`
Expected: PASS

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/run_record_test.rb`
Expected: PASS

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/worker_test.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add load/lib/load/client.rb load/lib/load/metrics.rb load/lib/load/reporter.rb load/lib/load/run_record.rb load/lib/load/worker.rb load/test/metrics_test.rb load/test/reporter_test.rb load/test/run_record_test.rb load/test/worker_test.rb JOURNAL.md
git commit -m "feat: add load runner execution primitives"
```

### Task 3: Adapter Client, Workload Loader, Runner, and CLI

**Files:**
- Create: `load/lib/load/adapter_client.rb`
- Create: `load/lib/load/runner.rb`
- Create: `load/test/adapter_client_test.rb`
- Create: `load/test/runner_test.rb`
- Create: `load/test/cli_test.rb`
- Create: `bin/load`
- Modify: `.gitignore`

- [ ] **Step 1: Write the failing adapter client, runner, and CLI tests**

```ruby
# load/test/adapter_client_test.rb
def test_reset_state_passes_seed_and_scale_env
  capture = FakeCapture3.new(stdout: %({"ok":true,"command":"reset-state"}))
  client = Load::AdapterClient.new(adapter_bin: "adapters/rails/bin/bench-adapter", capture3: capture)

  client.reset_state(app_root: "/tmp/app", scale: Load::Scale.new(rows_per_table: 10_000_000, open_fraction: 0.002, seed: 42))

  assert_equal ["reset-state", "--app-root", "/tmp/app", "--seed", "42", "--env", "ROWS_PER_TABLE=10000000", "--env", "OPEN_FRACTION=0.002"], capture.argv
end

# load/test/runner_test.rb
def test_runner_always_stops_adapter_and_writes_outcome
  run_record = FakeRunRecord.new
  adapter = FakeAdapterClient.new
  runner = Load::Runner.new(workload: FakeWorkload.new, adapter_client: adapter, run_record:, clock: fake_clock, sleeper: ->(*) {})

  runner.run

  assert_equal 1, adapter.stop_calls
  assert_equal false, run_record.outcome.fetch(:aborted)
end

def test_runner_sets_aborted_true_on_sigint_and_still_stops_adapter
  run_record = FakeRunRecord.new
  adapter = FakeAdapterClient.new
  stop_flag = StopFlag.new
  runner = Load::Runner.new(workload: FakeWorkload.new, adapter_client: adapter, run_record:, clock: fake_clock, sleeper: ->(*) {}, stop_flag:)

  Thread.new { sleep(0.01); stop_flag.trigger(:sigint) }
  runner.run

  assert_equal true, run_record.outcome.fetch(:aborted)
  assert_equal 1, adapter.stop_calls  # ensure block must run even on signal-driven abort
end

def test_runner_readiness_probe_exits_one_on_timeout
  run_record = FakeRunRecord.new
  adapter = FakeAdapterClient.new(start_response: {"ok" => true, "pid" => 123, "base_url" => "http://127.0.0.1:3999"})
  http = FakeHttp.new(always_refuse: true)  # connection refused on every probe
  runner = Load::Runner.new(workload: FakeWorkload.new, adapter_client: adapter, run_record:, clock: fake_clock, sleeper: ->(*) {}, http:, readiness_timeout_seconds: 0.1)

  exit_code = runner.run

  assert_equal 1, exit_code
  assert_equal "readiness_timeout", run_record.outcome.fetch(:error_code)
  assert_equal 1, adapter.stop_calls
end

def test_runner_pins_window_start_ts_at_first_successful_request
  # Spec §8.1 step 12: start_ts is pinned after first ok response, not at grace start.
  run_record = FakeRunRecord.new
  runner = build_runner_with_delayed_first_success(delay_ms: 250, run_record:)

  runner.run

  grace_end = run_record.readiness.fetch(:completed_at)
  first_ok = run_record.window.fetch(:start_ts)
  assert first_ok >= grace_end, "start_ts must be >= readiness completion"
end

# load/test/cli_test.rb
def test_run_command_exits_zero_on_successful_run
  status = run_bin_load("run", "--workload", fixture_workload_path, "--adapter", "fake-adapter", "--app-root", "/tmp/demo", runner: FakeRunner.new(exit_code: 0))
  assert_equal 0, status
end

def test_run_command_exits_one_on_adapter_error
  status = run_bin_load("run", "--workload", fixture_workload_path, "--adapter", "fake-adapter", "--app-root", "/tmp/demo", runner: FakeRunner.new(exit_code: 1))
  assert_equal 1, status
end

def test_run_command_exits_two_when_workload_file_missing
  status = run_bin_load("run", "--workload", "/nonexistent.rb", "--adapter", "fake-adapter", "--app-root", "/tmp/demo")
  assert_equal 2, status
end

def test_run_command_exits_two_when_workload_file_defines_no_subclass
  path = Tempfile.create(["bad_workload", ".rb"]) { |f| f.write("# no Load::Workload subclass\n") ; f.path }
  status = run_bin_load("run", "--workload", path, "--adapter", "fake-adapter", "--app-root", "/tmp/demo")
  assert_equal 2, status
end

def test_run_command_exits_three_when_no_successful_requests
  status = run_bin_load("run", "--workload", fixture_workload_path, "--adapter", "fake-adapter", "--app-root", "/tmp/demo", runner: FakeRunner.new(exit_code: 3))
  assert_equal 3, status
end
```

**CLI DI seam (for unit testing without real subprocess spawns):**

```ruby
# Load::CLI's constructor accepts a `runner:` kwarg whose default is the real
# runner factory. Tests pass a FakeRunner; production code passes nothing.
module Load
  class CLI
    def initialize(argv:, stdout:, stderr:, runner: Load::Runner.method(:new))
      @argv, @stdout, @stderr, @runner_factory = argv, stdout, stderr, runner
    end

    def run
      # ... parse argv, load workload, build adapter_client, then:
      runner = @runner_factory.call(workload:, adapter_client:, run_record:, ...)
      runner.run
    end
  end
end
```

`bin/load` passes only `argv:`, `stdout:`, `stderr:`; tests supply a `runner:` double and bypass the real `Load::Runner` entirely. This is the unit-test seam for the CLI — it means `cli_test.rb` never spawns a real Rails server.

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/adapter_client_test.rb`
Expected: `Load::AdapterClient` is undefined.

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb`
Expected: `Load::Runner` is undefined.

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/cli_test.rb`
Expected: `bin/load` does not exist.

- [ ] **Step 3: Implement the adapter wrapper, workload loader, runner orchestration, and `bin/load`**

```ruby
# load/lib/load/adapter_client.rb
module Load
  class AdapterClient
    def reset_state(app_root:, scale:)
      invoke(
        "reset-state",
        "--app-root", app_root,
        "--seed", scale.seed.to_s,
        *scale.env_pairs.flat_map { |key, value| ["--env", "#{key}=#{value}"] },
      )
    end
  end
end

# bin/load
require_relative "../load/lib/load"

command = ARGV.shift
if command == "run"
  # Production path: CLI constructs a real Load::Runner via the default factory.
  # Tests pass a `runner:` kwarg to short-circuit subprocess spawning.
  exit Load::CLI.new(argv: ARGV, stdout: $stdout, stderr: $stderr).run
end

warn "usage: bin/load run --workload PATH --adapter PATH --app-root PATH [--readiness-path /up|none] [--startup-grace-seconds 15]"
exit 2
```

The `Load::Runner` implementation MUST include the deterministic readiness probe (spec §8.2): after `adapter.start` returns, poll `GET <base_url><readiness_path>` with exponential backoff (200ms, 400ms, 800ms, 1600ms, capped) until first 2xx or until `--startup-grace-seconds`. On timeout: set `run_record.outcome.error_code = "readiness_timeout"`, call `adapter.stop`, return exit code 1. When `--readiness-path none`, fall back to `sleep(startup_grace_seconds)`. The runner pins `window.start_ts` only after the first worker records an ok response — never before.

- [ ] **Step 4: Run the focused runner tests and the new CLI test**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/adapter_client_test.rb`
Expected: PASS

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb`
Expected: PASS

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/cli_test.rb`
Expected: PASS

- [ ] **Step 5: Add `runs/` to `.gitignore` and commit**

```bash
git add load/lib/load/adapter_client.rb load/lib/load/runner.rb load/test/adapter_client_test.rb load/test/runner_test.rb load/test/cli_test.rb bin/load .gitignore JOURNAL.md
git commit -m "feat: add load runner orchestration"
```

### Task 4: Rails Adapter Command Unit Tests and Implementation

**Files:**
- Create: `adapters/rails/bin/bench-adapter`
- Create: `adapters/rails/lib/rails_adapter.rb`
- Create: `adapters/rails/lib/rails_adapter/result.rb`
- Create: `adapters/rails/lib/rails_adapter/command_runner.rb`
- Create: `adapters/rails/lib/rails_adapter/port_finder.rb`
- Create: `adapters/rails/lib/rails_adapter/template_cache.rb`
- Create: `adapters/rails/lib/rails_adapter/commands/describe.rb`
- Create: `adapters/rails/lib/rails_adapter/commands/prepare.rb`
- Create: `adapters/rails/lib/rails_adapter/commands/migrate.rb`
- Create: `adapters/rails/lib/rails_adapter/commands/load_dataset.rb`
- Create: `adapters/rails/lib/rails_adapter/commands/reset_state.rb`
- Create: `adapters/rails/lib/rails_adapter/commands/start.rb`
- Create: `adapters/rails/lib/rails_adapter/commands/stop.rb`
- Create: `adapters/rails/test/test_helper.rb`
- Create: `adapters/rails/test/describe_test.rb`
- Create: `adapters/rails/test/prepare_test.rb`
- Create: `adapters/rails/test/migrate_test.rb`
- Create: `adapters/rails/test/load_dataset_test.rb`
- Create: `adapters/rails/test/reset_state_test.rb`
- Create: `adapters/rails/test/start_test.rb`
- Create: `adapters/rails/test/stop_test.rb`

- [ ] **Step 1: Write failing unit tests for each command**

```ruby
# adapters/rails/test/prepare_test.rb
def test_prepare_fails_fast_when_bundle_check_fails
  # Spec §5.2: prepare does NOT auto-install. It calls `bundle check` and fails fast.
  runner = FakeCommandRunner.new(results: { ["bundle", "check"] => FakeResult.new(status: 1, stdout: "", stderr: "deps missing") })
  command = RailsAdapter::Commands::Prepare.new(app_root: "/tmp/demo", command_runner: runner)

  result = command.call

  refute result.fetch("ok")
  assert_equal "bundle_missing", result.dig("error", "code")
  refute_includes runner.argv_history, ["bundle", "install"]  # must NOT have tried install
end

# adapters/rails/test/load_dataset_test.rb
def test_load_dataset_runs_rails_runner_with_scale_env
  runner = FakeCommandRunner.new
  command = RailsAdapter::Commands::LoadDataset.new(app_root: "/tmp/demo", workload: "missing-index-todos", seed: 42, env_pairs: { "ROWS_PER_TABLE" => "10000000", "OPEN_FRACTION" => "0.002" }, command_runner: runner, clock: fake_clock)

  result = command.call

  assert_equal "load-dataset", result.fetch("command")
  assert_includes runner.env.fetch("SEED"), "42"
  assert_includes runner.argv, %(load Rails.root.join("db/seeds.rb").to_s)
end

# adapters/rails/test/reset_state_test.rb
def test_reset_state_uses_template_clone_after_first_build
  cache = FakeTemplateCache.new
  command = RailsAdapter::Commands::ResetState.new(app_root: "/tmp/demo", seed: 42, env_pairs: {}, command_runner: FakeCommandRunner.new, template_cache: cache, clock: fake_clock)

  command.call
  command.call

  assert_equal 1, cache.build_calls
  assert_equal 1, cache.clone_calls
end

def test_reset_state_resets_pg_stat_statements_counters
  # Spec §5.2: reset-state must run pg_stat_statements_reset() so per-run counters
  # start at zero. Parity with today's fixtures/missing-index/setup/reset.rb which
  # does `worker.exec("SELECT pg_stat_statements_reset()")`.
  runner = FakeCommandRunner.new
  command = RailsAdapter::Commands::ResetState.new(app_root: "/tmp/demo", seed: 42, env_pairs: {}, command_runner: runner, template_cache: FakeTemplateCache.new, clock: fake_clock)

  command.call

  rails_runner_calls = runner.argv_history.select { |argv| argv.first(2) == ["bin/rails", "runner"] }
  assert rails_runner_calls.any? { |argv| argv.last.include?("pg_stat_statements_reset") }, "expected a bin/rails runner call that invokes pg_stat_statements_reset()"
end

# adapters/rails/test/start_test.rb
def test_start_returns_port_exhausted_when_all_ports_busy
  # Spec §6.3: ports 3000..3020 tried in order; if all busy, return error.
  port_finder = FakePortFinder.new(all_busy: true)
  command = RailsAdapter::Commands::Start.new(app_root: "/tmp/demo", port_finder:, spawner: FakeSpawner.new)

  result = command.call

  refute result.fetch("ok")
  assert_equal "port_exhausted", result.dig("error", "code")
end

def test_start_does_not_call_process_detach
  # Spec §6.3: Process.detach installs a reaper thread that races stop's waitpid.
  # The adapter must NOT detach. On Linux the child is reparented to init when
  # the adapter exits after emitting JSON — this is sufficient.
  spawner = FakeSpawner.new
  command = RailsAdapter::Commands::Start.new(app_root: "/tmp/demo", port_finder: FakePortFinder.new(port: 3000), spawner:)

  command.call

  assert_equal 0, spawner.detach_calls
end

# adapters/rails/test/stop_test.rb
def test_stop_returns_ok_true_on_unknown_pid
  # Spec §6.4: ESRCH (no such process) is idempotent success.
  killer = FakeProcessKiller.new(kill_raises: { "TERM" => Errno::ESRCH })
  command = RailsAdapter::Commands::Stop.new(pid: 99999, process_killer: killer, clock: fake_clock, sleeper: ->(*) {})

  result = command.call

  assert result.fetch("ok")
end

def test_stop_escalates_to_sigkill_after_ten_second_term_budget
  # Spec §6.4: SIGTERM, poll via kill(0, pid) for 10s, then SIGKILL.
  # NEVER waitpid — start and stop run in different adapter processes, so waitpid
  # would raise ECHILD. Existence polling via kill(0, pid) is the contract.
  clock = FakeClock.new([0.0, 2.0, 4.0, 6.0, 8.0, 10.5])  # exceed 10s budget
  killer = FakeProcessKiller.new(alive: true)  # kill(0, pid) keeps succeeding
  command = RailsAdapter::Commands::Stop.new(pid: 12345, process_killer: killer, clock:, sleeper: ->(*) {})

  command.call

  assert_includes killer.signals_sent, "TERM"
  assert_includes killer.signals_sent, "KILL"
end

def test_stop_never_calls_waitpid
  # Regression guard: waitpid on a non-child pid raises Errno::ECHILD.
  killer = FakeProcessKiller.new(dies_after_term: true)
  command = RailsAdapter::Commands::Stop.new(pid: 12345, process_killer: killer, clock: fake_clock, sleeper: ->(*) {})

  command.call

  assert_equal 0, killer.waitpid_calls
end

# adapters/rails/test/describe_test.rb (error-shape test belongs on any command, describe is simplest)
def test_error_response_shape_matches_contract
  # Spec §5.1: errors are {ok:false, command:<name>, error:{code, message, details}}.
  command = RailsAdapter::Commands::Describe.new(force_failure: StandardError.new("synthetic"))

  result = command.call

  refute result.fetch("ok")
  assert_equal "describe", result.fetch("command")
  assert_kind_of String, result.dig("error", "code")
  assert_kind_of String, result.dig("error", "message")
  assert_kind_of Hash, result.dig("error", "details")
end
```

- [ ] **Step 2: Run the adapter unit tests to verify they fail**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby adapters/rails/test/load_dataset_test.rb`
Expected: `RailsAdapter` is undefined.

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby adapters/rails/test/reset_state_test.rb`
Expected: `RailsAdapter::Commands::ResetState` is undefined.

- [ ] **Step 3: Implement the adapter command classes and the JSON CLI**

Implementation notes per command, keyed to spec sections:

- **Prepare (§5.2):** `bundle check` only. On non-zero exit, return `{ok:false, command:"prepare", error:{code:"bundle_missing", message:..., details:{stderr:...}}}`. Never call `bundle install`. Also verify DB cluster reachable.
- **ResetState (§5.2):** after seed completes, run `bin/rails runner 'ActiveRecord::Base.connection.execute("SELECT pg_stat_statements_reset()")'` (or equivalent one-liner). Must run AFTER the template clone/seed, so counters capture only the run itself.
- **Start (§6.3):** spawn Rails server with explicit port from `PortFinder` (3000..3020). If all busy, return `{ok:false, error:{code:"port_exhausted"}}`. **Do NOT** call `Process.detach`. Return immediately with pid + base_url.
- **Stop (§6.4):** `SIGTERM`, then poll `Process.kill(0, pid)` every 200ms up to 10s. If still alive, `SIGKILL`, poll another 2s. On `Errno::ESRCH` at any step, return ok. **Never** call `Process.waitpid`.
- **TemplateCache:** connects to Postgres via `BENCH_ADAPTER_PG_ADMIN_URL` (falls back to `DATABASE_URL`). Runs `CREATE DATABASE <name>_tmpl TEMPLATE <name>` on first build. On subsequent calls: `pg_terminate_backend` other sessions on `<name>`, `DROP DATABASE <name>`, `CREATE DATABASE <name> TEMPLATE <name>_tmpl`. Invalidates on migration-version hash + scale-fields hash mismatch. Document this adapter-private PG admin capability in `adapters/rails/README.md` — it's the one intentional exception to "adapter talks to PG only through Rails."

```ruby
# adapters/rails/lib/rails_adapter/commands/load_dataset.rb
module RailsAdapter
  module Commands
    class LoadDataset
      def call
        started_at = @clock.call
        @command_runner.capture3(
          ["BUNDLE_GEMFILE", File.join(@app_root, "Gemfile")],
          ["RAILS_ENV", "benchmark"],
          ["RAILS_LOG_LEVEL", "warn"],
          ["SEED", @seed.to_s],
          *@env_pairs.to_a,
          "bin/rails", "runner", %(load Rails.root.join("db/seeds.rb").to_s),
          chdir: @app_root,
        )
        {
          "ok" => true,
          "command" => "load-dataset",
          "loaded_rows" => @env_pairs.fetch("ROWS_PER_TABLE", nil),
          "duration_ms" => elapsed_ms(started_at),
        }
      end
    end
  end
end
```

- [ ] **Step 4: Run the adapter unit suite**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby adapters/rails/test/describe_test.rb`
Expected: PASS

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby adapters/rails/test/prepare_test.rb`
Expected: PASS

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby adapters/rails/test/migrate_test.rb`
Expected: PASS

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby adapters/rails/test/load_dataset_test.rb`
Expected: PASS

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby adapters/rails/test/reset_state_test.rb`
Expected: PASS

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby adapters/rails/test/start_test.rb`
Expected: PASS

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby adapters/rails/test/stop_test.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add adapters/rails/bin/bench-adapter adapters/rails/lib/rails_adapter.rb adapters/rails/lib/rails_adapter/result.rb adapters/rails/lib/rails_adapter/command_runner.rb adapters/rails/lib/rails_adapter/port_finder.rb adapters/rails/lib/rails_adapter/template_cache.rb adapters/rails/lib/rails_adapter/commands adapters/rails/test JOURNAL.md
git commit -m "feat: add rails benchmark adapter"
```

### Task 5: Rails Adapter Integration and External Seed Dependency

**Files:**
- Create: `adapters/rails/test/integration_test.rb`
- Create: `adapters/rails/test/fixtures/demo_app/` files
- Create: `adapters/rails/README.md`
- Modify: `/home/bjw/db-specialist-demo/config/database.yml`
- Modify: `/home/bjw/db-specialist-demo/db/seeds.rb`

- [ ] **Step 1: Write the failing integration test for the adapter lifecycle**

Spec §14.2: this integration test is **opt-in** via `RUN_RAILS_INTEGRATION=1`, not opt-out. The default CI path skips it because not every dev machine has a Rails stack; nightly / pre-release runs set the flag.

```ruby
def test_prepare_migrate_load_start_and_stop_against_fixture_app
  skip "set RUN_RAILS_INTEGRATION=1 to run" unless ENV["RUN_RAILS_INTEGRATION"] == "1"

  app_root = File.expand_path("fixtures/demo_app", __dir__)
  adapter = bench_adapter_bin

  assert_command_ok adapter, "prepare", "--app-root", app_root
  assert_command_ok adapter, "migrate", "--app-root", app_root
  assert_command_ok adapter, "load-dataset", "--app-root", app_root, "--workload", "demo", "--seed", "7", "--env", "ROWS_PER_TABLE=10", "--env", "OPEN_FRACTION=0.2"
  start = assert_command_ok adapter, "start", "--app-root", app_root
  assert_equal "200", Net::HTTP.get_response(URI("#{start.fetch("base_url")}/up")).code
  assert_command_ok adapter, "stop", "--pid", start.fetch("pid").to_s
end

def test_real_db_specialist_demo_end_to_end
  # Spec §14.3: real end-to-end against external ~/db-specialist-demo, skip-by-default.
  # Exercised by Task 9's parity verification. This test is the unit-addressable form.
  skip "set RUN_DB_SPECIALIST_DEMO_INTEGRATION=1 and DB_SPECIALIST_DEMO_PATH" unless ENV["RUN_DB_SPECIALIST_DEMO_INTEGRATION"] == "1" && ENV["DB_SPECIALIST_DEMO_PATH"]

  app_root = ENV.fetch("DB_SPECIALIST_DEMO_PATH")
  adapter = bench_adapter_bin
  assert_command_ok adapter, "prepare", "--app-root", app_root
  assert_command_ok adapter, "reset-state", "--app-root", app_root, "--seed", "42", "--env", "ROWS_PER_TABLE=1000", "--env", "OPEN_FRACTION=0.002"
  start = assert_command_ok adapter, "start", "--app-root", app_root
  assert_equal "200", Net::HTTP.get_response(URI("#{start.fetch("base_url")}/up")).code
  assert_command_ok adapter, "stop", "--pid", start.fetch("pid").to_s
end
```

- [ ] **Step 2: Run the integration test and confirm the current implementation gaps**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby adapters/rails/test/integration_test.rb`
Expected: FAIL until the fixture app and command wiring exist.

- [ ] **Step 3: Implement the minimal fixture app and land the external seed dependency**

```ruby
# /home/bjw/db-specialist-demo/config/database.yml
benchmark:
  <<: *default
  adapter: postgresql
  url: <%= ENV.fetch("DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/checkpoint_demo") %>

# /home/bjw/db-specialist-demo/db/seeds.rb
rows_per_table = Integer(ENV.fetch("ROWS_PER_TABLE", "10000"))
seed_value = Integer(ENV.fetch("SEED", "42"))
open_fraction = Float(ENV.fetch("OPEN_FRACTION", "0.002"))

ActiveRecord::Base.connection.execute(<<~SQL)
  SELECT setseed(#{seed_value.to_f / 1000});
  INSERT INTO users (name, created_at, updated_at)
  SELECT 'user_' || i, NOW(), NOW()
  FROM generate_series(1, 1000) AS i;

  INSERT INTO todos (title, status, user_id, created_at, updated_at)
  SELECT
    'todo ' || i,
    CASE WHEN random() < #{open_fraction} THEN 'open' ELSE 'closed' END,
    (random() * 999 + 1)::int,
    NOW(),
    NOW()
  FROM generate_series(1, #{rows_per_table}) AS i;

  ANALYZE users;
  ANALYZE todos;
SQL
```

- [ ] **Step 4: Run the integration test and a manual seed smoke check**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby adapters/rails/test/integration_test.rb`
Expected: PASS

Run: `cd /home/bjw/db-specialist-demo && DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo RAILS_ENV=benchmark SEED=42 ROWS_PER_TABLE=1000 OPEN_FRACTION=0.002 BUNDLE_USER_HOME=/tmp/bundle BUNDLE_PATH=vendor/bundle bundle exec rails runner 'load Rails.root.join("db/seeds.rb").to_s'`
Expected: exits 0 and seeds benchmark rows through Postgres SQL, not ActiveRecord loops.

- [ ] **Step 5: Commit both repos separately**

```bash
git -C /home/bjw/db-specialist-demo add config/database.yml db/seeds.rb
git -C /home/bjw/db-specialist-demo commit -m "feat: parameterize benchmark seeds"

git add adapters/rails/test/integration_test.rb adapters/rails/test/fixtures adapters/rails/README.md JOURNAL.md
git commit -m "test: cover rails adapter integration"
```

### Task 6: Missing-Index Workload and Oracle

**Files:**
- Create: `workloads/missing_index_todos/workload.rb`
- Create: `workloads/missing_index_todos/actions/list_open_todos.rb`
- Create: `workloads/missing_index_todos/oracle.rb`
- Create: `workloads/missing_index_todos/README.md`
- Create: `workloads/missing_index_todos/test/workload_test.rb`
- Create: `workloads/missing_index_todos/test/oracle_test.rb`

- [ ] **Step 1: Write the failing workload and oracle tests**

```ruby
# workloads/missing_index_todos/test/workload_test.rb
def test_workload_matches_missing_index_defaults
  workload = Load::Workloads::MissingIndexTodos.new

  assert_equal "missing-index-todos", workload.name
  assert_equal 10_000_000, workload.scale.rows_per_table
  assert_equal 0.002, workload.scale.open_fraction
  assert_equal 16, workload.load_plan.workers  # parity with fixtures/missing-index/manifest.yml
  assert_equal :unlimited, workload.load_plan.rate_limit
end

# workloads/missing_index_todos/test/oracle_test.rb
def test_oracle_tree_walk_finds_seq_scan_under_wrapper_nodes
  # Spec §11: oracle walks the plan tree and asserts *some* node on relation
  # `todos` has Node Type == "Seq Scan". Must not rely on root shape — Rails
  # may wrap the scan in Limit/Gather/Sort depending on query construction.
  plan_with_gather_wrapping_seq_scan = {
    "Node Type" => "Gather",
    "Plans" => [
      { "Node Type" => "Seq Scan", "Relation Name" => "todos" },
    ],
  }
  oracle = Load::Workloads::MissingIndexTodos::Oracle.new(pg: fake_pg_with_plan_node(plan_with_gather_wrapping_seq_scan), clickhouse_query: ->(*) { { "total_exec_count" => "600" } }, sleeper: ->(*) {})

  oracle.run([fixture_run_dir])  # must NOT exit 1
end

def test_oracle_fails_when_plan_relation_node_is_not_seq_scan
  oracle = Load::Workloads::MissingIndexTodos::Oracle.new(pg: fake_pg_with_plan("Index Scan"), clickhouse_query: ->(*) { { "total_exec_count" => "600" } }, sleeper: ->(*) {})

  error = assert_raises(SystemExit) { oracle.run([fixture_run_dir]) }
  assert_equal 1, error.status
end

def test_oracle_uses_queryid_fingerprint_not_sql_text_match
  # Spec §11: identify statements by pg_stat_statements.queryid, not SQL LIKE.
  # Pass two queryids (parameter-variant queries with same normalized text);
  # oracle sums total_exec_count across them.
  ch_responses = [
    { "queryid" => "111", "total_exec_count" => "250" },
    { "queryid" => "222", "total_exec_count" => "300" },
  ]
  oracle = Load::Workloads::MissingIndexTodos::Oracle.new(pg: fake_pg_with_queryids(["111", "222"]), clickhouse_query: ->(*) { ch_responses }, sleeper: ->(*) {})

  oracle.run([fixture_run_dir])  # sum = 550 >= 500, must PASS
end

def test_oracle_fails_with_clear_message_on_clickhouse_timeout
  # Spec §11: timeout path prints "FAIL: clickhouse (saw N calls before timeout)" and exits 1.
  stuck_response = { "total_exec_count" => "42" }  # never reaches 500
  ch_calls = 0
  ch_stub = ->(*) { ch_calls += 1; stuck_response }
  clock = FakeClock.new(Array.new(50) { |i| i * 1.0 })
  oracle = Load::Workloads::MissingIndexTodos::Oracle.new(pg: fake_pg_with_plan("Seq Scan"), clickhouse_query: ch_stub, clock:, sleeper: ->(*) {}, clickhouse_timeout_seconds: 30)

  error = assert_raises(SystemExit) { oracle.run([fixture_run_dir]) }
  assert_equal 1, error.status
  assert ch_calls > 1, "oracle must poll ClickHouse more than once before timing out"
end
```

- [ ] **Step 2: Run the workload/oracle tests to verify they fail**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby workloads/missing_index_todos/test/workload_test.rb`
Expected: `Load::Workloads::MissingIndexTodos` is undefined.

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby workloads/missing_index_todos/test/oracle_test.rb`
Expected: oracle file does not exist.

- [ ] **Step 3: Implement the workload and port the tactical oracle from the fixture harness**

```ruby
# workloads/missing_index_todos/workload.rb
module Load
  module Workloads
    class MissingIndexTodos < Load::Workload
      def name = "missing-index-todos"

      def scale
        Load::Scale.new(rows_per_table: 10_000_000, open_fraction: 0.002, seed: 42)
      end

      def actions
        [Load::ActionEntry.new(Actions::ListOpenTodos, 100)]
      end

      def load_plan
        # 16 workers: parity with today's fixtures/missing-index/manifest.yml.
        # The old 4-worker default silently regressed concurrency vs the harness
        # being replaced; parity check in Task 8 depends on this matching.
        Load::LoadPlan.new(workers: 16, duration_seconds: 60, rate_limit: :unlimited, seed: nil)
      end
    end
  end
end
```

**Oracle implementation notes (spec §11):**

1. Tree-walk the EXPLAIN plan recursively. Assert *some* node in the tree has `Node Type == "Seq Scan"` AND `Relation Name == "todos"`. Do NOT match on root shape (Rails sometimes wraps the scan in `Limit`/`Gather`/`Sort`). Reject on `Index Scan` / `Index Only Scan` / `Bitmap Index Scan` on `todos`.
2. Identify target statement(s) by `pg_stat_statements.queryid`, NOT by `SQL LIKE '%todos%status%'`. At setup time, run the canonical `EXPLAIN` and capture its `queryid`. Multiple queryids with matching normalized text: sum `total_exec_count` across them.
3. Poll ClickHouse for `sum(total_exec_count) >= 500` across the matched queryid set for the run window. Default timeout: 30s past `window.end_ts`. On timeout: `FAIL: clickhouse (saw N calls before timeout)`, exit 1.

- [ ] **Step 4: Run the workload/oracle tests**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby workloads/missing_index_todos/test/workload_test.rb`
Expected: PASS

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby workloads/missing_index_todos/test/oracle_test.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add workloads/missing_index_todos/workload.rb workloads/missing_index_todos/actions/list_open_todos.rb workloads/missing_index_todos/oracle.rb workloads/missing_index_todos/README.md workloads/missing_index_todos/test/workload_test.rb workloads/missing_index_todos/test/oracle_test.rb JOURNAL.md
git commit -m "feat: add missing-index workload and oracle"
```

### Task 7: Docs, Smoke Target, and Top-Level Verification Path

**Files:**
- Modify: `README.md`
- Modify: `Makefile`
- Create: `load/test/load_smoke_target_test.rb`

- [ ] **Step 1: Write the failing smoke-target and README assertions**

```ruby
def test_makefile_exposes_load_smoke_target
  makefile = File.read(File.expand_path("../../Makefile", __dir__))
  assert_includes makefile, ".PHONY: load-smoke"
  assert_includes makefile, "bin/load run --workload workloads/missing_index_todos/workload.rb"
end
```

- [ ] **Step 2: Run the smoke-target test to verify it fails**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/load_smoke_target_test.rb`
Expected: `load-smoke` target is missing.

- [ ] **Step 3: Rewrite the top-level docs for the new runner**

```make
.PHONY: load-smoke

load-smoke:
	bin/load run --workload workloads/missing_index_todos/workload.rb --adapter adapters/rails/bin/bench-adapter --app-root /home/bjw/db-specialist-demo
```

```md
# Checkpoint Collector

This repo owns the collector pipeline, ClickHouse DDLs, local Postgres image,
and the load runner used to generate database traffic against external apps.

## Local Run

```bash
docker compose up -d postgres clickhouse collector
make load-smoke
```
```

- [ ] **Step 4: Run the smoke-target test**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/load_smoke_target_test.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add README.md Makefile load/test/load_smoke_target_test.rb JOURNAL.md
git commit -m "docs: add load runner smoke path"
```

### Task 8: End-to-End Verification and Parity Check

**Verify before you delete.** Task 9 removes the old harness; this task proves the new runner reaches parity against the real external app at pinned SHAs BEFORE anything is deleted. If parity fails here, the old harness is still intact and a fix is easy; if the old harness were already gone, debugging regressions would be much harder.

**Files:**
- Modify: `JOURNAL.md`

- [ ] **Step 1: Pin db-specialist-demo SHAs and record them**

Before running parity, pin the exact commits the runner will be verified against. The external repo is a moving target; parity against "whatever `master` happens to point to today" is not reproducible.

```bash
DEMO_MASTER_SHA=$(git -C /home/bjw/db-specialist-demo rev-parse master)
DEMO_ORACLE_SHA=$(git -C /home/bjw/db-specialist-demo rev-parse oracle/add-index)
echo "db-specialist-demo master: $DEMO_MASTER_SHA"
echo "db-specialist-demo oracle/add-index: $DEMO_ORACLE_SHA"
```

Record both SHAs into `JOURNAL.md` under today's date. Reference them in the run.json-adjacent verification notes so a future reader can reproduce the exact parity run.

- [ ] **Step 2: Bring up the collector stack from a clean state**

Run: `docker compose down -v`
Expected: existing Postgres, ClickHouse, and collector containers stop and volumes are removed.

Run: `docker compose up -d --build postgres clickhouse collector`
Expected: all three services report healthy or running.

- [ ] **Step 3: Run the full Ruby test surface**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/rate_limiter_test.rb`
Expected: PASS

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/selector_test.rb`
Expected: PASS

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/metrics_test.rb`
Expected: PASS

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/reporter_test.rb`
Expected: PASS

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/adapter_client_test.rb`
Expected: PASS

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/run_record_test.rb`
Expected: PASS

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb`
Expected: PASS

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/worker_test.rb`
Expected: PASS

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/cli_test.rb`
Expected: PASS

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/load_smoke_target_test.rb`
Expected: PASS

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby adapters/rails/test/describe_test.rb`
Expected: PASS

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby adapters/rails/test/prepare_test.rb`
Expected: PASS

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby adapters/rails/test/migrate_test.rb`
Expected: PASS

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby adapters/rails/test/load_dataset_test.rb`
Expected: PASS

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby adapters/rails/test/reset_state_test.rb`
Expected: PASS

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby adapters/rails/test/start_test.rb`
Expected: PASS

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby adapters/rails/test/stop_test.rb`
Expected: PASS

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby adapters/rails/test/integration_test.rb`
Expected: PASS or `skip` when intentionally disabled.

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby workloads/missing_index_todos/test/workload_test.rb`
Expected: PASS

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby workloads/missing_index_todos/test/oracle_test.rb`
Expected: PASS

- [ ] **Step 4: Verify parity against the pinned `db-specialist-demo` master SHA (runs #1 and #2)**

Run: `git -C /home/bjw/db-specialist-demo checkout $DEMO_MASTER_SHA`
Expected: detached HEAD at the pinned master SHA.

Run (TWICE, consecutively — Codex recommendation, catches first-run/second-run divergence):
```
bin/load run --workload workloads/missing_index_todos/workload.rb --adapter adapters/rails/bin/bench-adapter --app-root /home/bjw/db-specialist-demo
ruby workloads/missing_index_todos/oracle.rb "$(ls -dt runs/*-missing-index-todos | head -n1)"
```
Expected both runs: load runner exits `0`, oracle prints `PASS: explain` and `PASS: clickhouse`, exits `0`. Two consecutive passes (not one) are required to lock parity — second run exercises the template-clone code path, first run exercises the template-build path.

- [ ] **Step 5: Verify the oracle flips on the pinned `oracle/add-index` SHA**

Run: `git -C /home/bjw/db-specialist-demo checkout $DEMO_ORACLE_SHA`
Expected: detached HEAD at the pinned oracle/add-index SHA.

Run: `bin/load run --workload workloads/missing_index_todos/workload.rb --adapter adapters/rails/bin/bench-adapter --app-root /home/bjw/db-specialist-demo`
Expected: exit `0`, new run record written.

Run: `ruby workloads/missing_index_todos/oracle.rb "$(ls -dt runs/*-missing-index-todos | head -n1)"`
Expected: prints `FAIL: explain (expected Seq Scan, got Index Scan)` and exits `1`.

Run: `git -C /home/bjw/db-specialist-demo checkout $DEMO_MASTER_SHA`
Expected: demo app returns to the pinned master SHA.

- [ ] **Step 6: Record the exact verification output and commit**

Record both SHAs, the two PASS runs, and the FAIL run in `JOURNAL.md`.

```bash
git add JOURNAL.md
git commit -m "test: verify load runner parity at pinned db-specialist-demo SHAs"
```

### Task 9: Remove the Fixture Harness and Toy Harness

**Only after Task 8 parity has passed twice consecutively.** If any part of Task 8 failed, do not proceed — debug against the old harness first. Deletion is a one-way operation and should be the last step of this plan.

**Files:**
- Delete: `bin/fixture`
- Delete: `collector/lib/fixtures/command.rb`
- Delete: `collector/lib/fixtures/manifest.rb`
- Delete: `collector/test/fixtures/fixture_command_test.rb`
- Delete: `collector/test/fixtures/fixture_manifest_test.rb`
- Delete: `collector/test/fixtures/fixture_smoke_target_test.rb`
- Delete: `collector/test/fixtures/missing_index_assert_test.rb`
- Delete: `collector/test/fixtures/missing_index_drive_test.rb`
- Delete: `collector/test/fixtures/missing_index_reset_test.rb`
- Delete: `fixtures/missing-index/README.md`
- Delete: `fixtures/missing-index/load/drive.rb`
- Delete: `fixtures/missing-index/manifest.yml`
- Delete: `fixtures/missing-index/setup/01_schema.sql`
- Delete: `fixtures/missing-index/setup/02_seed.sql`
- Delete: `fixtures/missing-index/setup/reset.rb`
- Delete: `fixtures/missing-index/validate/assert.rb`
- Delete: `load/harness.rb`
- Delete: `load/test/harness_test.rb`
- Delete: `load/README.md`
- Delete: `fixture-harness-walkthrough.md`

- [ ] **Step 1: Confirm Task 8 passed twice consecutively**

Inspect `JOURNAL.md` for the two back-to-back PASS entries from Task 8 Step 4. If missing, STOP and re-run Task 8.

- [ ] **Step 2: Delete the old harness files**

```bash
rm bin/fixture
rm -r collector/lib/fixtures collector/test/fixtures fixtures/missing-index
rm load/harness.rb load/test/harness_test.rb load/README.md fixture-harness-walkthrough.md
```

Note: `fixtures/missing-index/load/drive.rb` is the source that Task 1 ported `RateLimiter` from. By this point the copy under `load/lib/load/rate_limiter.rb` is already tested in isolation, so the delete is safe.

- [ ] **Step 3: Run the replacement test suites to prove nothing still depends on the deleted code**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/rate_limiter_test.rb`
Expected: PASS

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/metrics_test.rb`
Expected: PASS

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb`
Expected: PASS

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby adapters/rails/test/integration_test.rb`
Expected: PASS or `skip` when `RUN_RAILS_INTEGRATION` is unset.

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby workloads/missing_index_todos/test/oracle_test.rb`
Expected: PASS

- [ ] **Step 4: Re-run Task 8's parity sequence once more to confirm no regression from deletion**

Run the same `bin/load run` + `oracle.rb` sequence as Task 8 Step 4 once.
Expected: same PASS result as before deletion.

- [ ] **Step 5: Commit the deletions**

```bash
git add bin/fixture collector/lib/fixtures collector/test/fixtures fixtures/missing-index load/harness.rb load/test/harness_test.rb load/README.md fixture-harness-walkthrough.md JOURNAL.md
git commit -m "refactor: replace fixture harness with load runner"
```

## Self-Review

- Spec coverage:
  - `/load` runner modules and run record: Tasks 1-3
  - Rails adapter contract and template caching: Tasks 4-5
  - `missing-index-todos` workload and tactical oracle: Task 6
  - `bin/load`, docs, smoke target: Tasks 3 and 7
  - parity verification (before deletion): Task 8
  - required deletions (only after parity): Task 9
  - external `db-specialist-demo` seed dependency: Cross-Repo Dependency section and Task 5
- Ordering invariant: parity (Task 8) runs BEFORE deletion (Task 9). If Task 8 fails, the old harness is still present and the branch is recoverable.
- Placeholder scan:
  - No `TODO`, `TBD`, or "similar to" placeholders remain.
- Type consistency:
  - `Scale` fields stay `rows_per_table`, `open_fraction`, `seed`.
  - `LoadPlan` fields stay `workers`, `duration_seconds`, `rate_limit`, `seed`.
  - Adapter commands stay exactly `describe`, `prepare`, `migrate`, `load-dataset`, `reset-state`, `start`, `stop`.

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Codex Review | `/codex review` (outside voice) | Independent 2nd opinion | 1 | DO NOT SHIP | 5 issues — 3 overlap with eng review, 2 new (process-group leak on stop; missing HTTP timeouts + blocking join) |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | DO NOT SHIP | 3 P0 (Reporter orphaned, adapter-commands.jsonl never written, no SIGINT/SIGTERM trap); 3 P1 (flaky `test_runner_preserves_explicit_zero_seed` under full-suite; no multi-worker rate limiter test; busy-wait at 100Hz in `wait_for_window_end`); 2 P2 (shared-hash reference in `write_state` snapshot, latent bug in `RailsAdapter::Result.wrap` — local var shadows method) |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | — |
| DX Review | `/plan-devex-review` | DevEx gaps | 0 | — | — |

**VERDICT:** DO NOT SHIP — 3 spec-mandated artifacts are not produced by the production path. Fix the artifact gap, the signal trap, and the process-group kill before merging.

### Eng Review — Unresolved issues

**P0 (blocking):**
1. `load/lib/load/runner.rb:110` `start_workers` never instantiates `Load::Reporter`. `metrics.jsonl` is mandated by spec §9 and never written. `Load::Reporter` is fully implemented and unit-tested (6 tests) but orphaned. Fix: construct Reporter with a sink lambda that calls `run_record.append_metrics`, `start` before threads, `stop` after `threads.each(&:join)`.
2. `load/lib/load/adapter_client.rb:44` never calls `run_record.append_adapter_command`. `adapter-commands.jsonl` is mandated by spec §9.2 and never written. `RunRecord#append_adapter_command` is defined and unreached. Fix: inject `run_record` into `AdapterClient` (or wrap invokes in `Runner`) and emit one line per adapter call with `command`, `argv`, `started_at`, `ended_at`, `exit_status`, `stdout_json`, `stderr`.
3. `bin/load` + `load/lib/load/cli.rb:17` have no `Signal.trap("INT")` / `Signal.trap("TERM")`. Spec §10 mandates "`SIGINT`/`SIGTERM` handled → set stop flag → `ensure` cleanup runs." Runner tests fake the sigint via `stop_flag.trigger(:sigint)` inside the sleeper — production path cannot be stopped cooperatively. Fix: in `bin/load` (or CLI entry), instantiate the runner's stop_flag, trap INT and TERM to trigger it, restore handlers after `runner.run`.

**P1:**
4. `load/test/runner_test.rb:213` `test_runner_preserves_explicit_zero_seed` fails ~2/3 of the time when the full `load/test/**` suite is run together (passes in isolation). Race: `wait_for_window_end` triggers `timeout` before worker thread completes one iteration. Confirmed via `for i in 1 2 3; do bundle exec ruby -e 'Dir["load/test/*_test.rb"].each{load _1}'; done`. Fix: replace clock-advance sleeper with a deterministic yield primitive, or poll-until-eventually with a generous wall-clock timeout.
5. `load/lib/load/rate_limiter.rb` has 2 single-threaded tests. With 16 workers in the default workload and a finite `rate_limit`, multi-worker mutex contention is not regression-tested. Fix: add an N-thread × M-call aggregate-rate test.
6. `load/lib/load/runner.rb:136` `wait_for_window_end` busy-waits at 100Hz via `@sleeper.call(0.01) + Thread.pass` for the full run (6000 iterations at default `duration_seconds=60`). Adds main-thread scheduler pressure under 16-worker load. Fix: sleep for `min(1.0, deadline - current_time)` or use a `ConditionVariable` signaled by `stop_flag.trigger`.

**P2:**
7. `load/lib/load/runner.rb:204` `write_state` captures `snapshot = @state` and writes outside the mutex. `deep_merge` returns new hashes at mutated levels, so current writers are safe, but nested hashes at unmutated keys are shared by reference — a future contributor who mutates nested state in place would introduce a TOCTOU. Fix: deep-clone the snapshot before releasing the lock, or add a comment documenting the contract.
8. `adapters/rails/lib/rails_adapter/result.rb:23-31` `wrap` has a latent bug: `rescue StandardError => error` binds `error` as a local, then the rescue body calls `error(command, classify(error), error.message, {})` — Ruby resolves `error(...)` with parens ambiguously depending on context; at minimum this is fragile, and `Result.wrap` is on the hot path via `describe.rb:11`. Fix: rename the exception variable (`rescue StandardError => exception`) and explicitly qualify `Result.error(...)`.

**Codex findings not covered above (P0):**
9. `adapters/rails/lib/rails_adapter/commands/start.rb:16` spawns Rails in its own process group (`pgroup: true`), but `stop.rb:13` signals only the leader pid. Rails server child workers survive and can hold ports/DB sessions between smoke runs. Fix: signal the group (`Process.kill("TERM", -pid)`) and poll group liveness.
10. `load/lib/load/client.rb` has no HTTP timeouts; `runner.rb:131` does a blocking `threads.each(&:join)`. One stuck request can hang the whole run and delay `adapter.stop`. Fix: set open/read/write timeouts on `Net::HTTP`; bound worker drain on stop.
11. `load/lib/load/runner.rb` `run.json` is underfilled: no `run_id`, no `probe_duration_ms`/`probe_attempts`, no `startup_grace_seconds`, no `metrics_interval_seconds`, no `query_ids`. `workloads/missing_index_todos/oracle.rb:94` falls back to a live `pg_stat_statements` query when `query_ids` is absent, which can misattribute DB activity to the wrong run. Fix: write the full run.json skeleton at start, persist probe stats and totals, record canonical queryids during reset into `run.json`.

### Eng Review — Critical gaps

- 3 spec-mandated artifacts not produced by production path (`metrics.jsonl`, `adapter-commands.jsonl`, no signal trap for cooperative shutdown).
- Implementation has Reporter and RunRecord append methods fully built, tested, and wired only to unit tests — they are orphaned from Runner.
- `run.json` is materially underfilled relative to spec §9; oracle falls back to live pg_stat_statements, which is unsafe for post-hoc verification.

### Eng Review — Commit reviewed

- Branch: `wip/fixture-harness-plan`
- HEAD: implementer-reported complete (not yet commit-hashed by reviewer; branch had uncommitted `.codex`, `.gstack/`, and `collector-correctness-walkthrough.md` at review start)
- Scope: `load/**`, `bin/load`, `adapters/rails/**`, `workloads/missing_index_todos/**`


## GSTACK REVIEW REPORT — Round 2 (2026-04-22)

Re-review after commits `24f51ec`, `7881180`, `916945f`, `5e385ce` on top of `264f2b0`.

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| Codex Review | `/codex review` (outside voice) | Independent 2nd opinion | 2 | SHIP WITH FIXES | All 6 prior P0 verified FIXED with file:line evidence. 2 new issues surfaced: adapter-commands.jsonl spec drift; run.json non-atomic writes. |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 2 | SHIP WITH FIXES | 6/6 P0 fixed. 2 P1 still failing (zero-seed test still flaky; new sigterm test also flakes on run.json read race). 1 new P1 (spec drift on adapter-commands.jsonl). 1 P2 (non-atomic run.json writes cause test flake; potential crash-truncation). |

**VERDICT:** SHIP WITH FIXES — the implementation now produces all spec-mandated artifacts, handles signals, kills the process group, and has HTTP timeouts + bounded drain. Three residual issues remain, all addressable before merge.

### P0 status (all fixed)

1. ✅ **Reporter wired** — `load/lib/load/runner.rb:141-152` constructs and starts Reporter, `:253-259` routes sink to `run_record.append_metrics`, stopped after `drain_workers`.
2. ✅ **adapter-commands.jsonl written** — `load/lib/load/adapter_client.rb:47-79` wraps every invoke with timing, logs on success AND on JSON::ParserError path. `run_record` injected via `load/lib/load/cli.rb:51`.
3. ✅ **SIGINT/SIGTERM trap** — `bin/load:20-31` installs traps and restores previous handlers in `ensure`. Verified by `load/test/cli_test.rb:170-206` spawning a real subprocess and sending SIGTERM.
4. ✅ **Process-group kill** — `adapters/rails/lib/rails_adapter/commands/stop.rb:14,17,30` use `process_group_pid` (`-@pid`) for TERM, KILL, and the alive-poll. Regression test in `adapters/rails/test/stop_test.rb`.
5. ✅ **HTTP timeouts + bounded drain** — `load/lib/load/client.rb:8,35-39` sets `HTTP_TIMEOUT_SECONDS = 5` on open/read/write. `load/lib/load/runner.rb:175-187` drain_workers enforces 1.0s deadline with Thread#raise(DrainTimeout) + Thread#kill fallback.
6. ✅ **run.json complete** — `load/lib/load/runner.rb:262-293` initial_state now has `run_id`, `workload.file`, `workload.actions`, `window.readiness.probe_duration_ms`/`probe_attempts`, `window.startup_grace_seconds`, `window.metrics_interval_seconds`, `query_ids`, `outcome.requests_total`/`requests_ok`/`requests_error`. Query_ids captured in `adapters/rails/lib/rails_adapter/commands/reset_state.rb:93-108` via a workload-keyed script.

### Unresolved issues

**P1 (fix before merge):**
1. **Spec drift in adapter-commands.jsonl** — spec §9.2 (`docs/superpowers/specs/2026-04-19-load-forge-mvp-design.md:498-504`) prescribes `{ts, command, args, exit_code, duration_ms, stdout_json, stderr}`. Implementation at `load/lib/load/adapter_client.rb:53-60` writes `{command, argv, started_at, ended_at, exit_status, stdout_json, stderr}`. Downstream consumers following the spec schema will break. Fix: rename `argv→args`, `exit_status→exit_code`, replace `started_at/ended_at` with `ts` (started_at) + derived `duration_ms`.

2. **`test_runner_preserves_explicit_zero_seed` still flaky** — `load/test/runner_test.rb:249`. 6 of 8 full-suite runs failed. Same race as before: `wait_for_window_end` timeout fires before worker thread completes one iteration. The new bounded `drain_workers` + `DrainTimeout` raise may actually make this worse by interrupting mid-iteration. Fix: deterministic yield primitive, or block until window_started OR deadline inside the test's workload.

3. **New flaky test: `test_bin_load_handles_sigterm_and_marks_run_aborted`** — `load/test/cli_test.rb:170`, failed once with `JSON::ParserError: unexpected token at ''` at line 321 (`JSON.parse(File.read(run_path))`). Root cause: `RunRecord#write_run` is not atomic — the file can be read mid-truncate. This is both a test flake and a durability concern for real runs.

**P2:**
4. **Non-atomic `run.json` writes** — `load/lib/load/run_record.rb:27-28` uses `File.write(run_path, JSON.pretty_generate(payload) + "\n")`. A crash or concurrent read mid-write can observe a truncated/empty file. Fix: write to `run.json.tmp` then `File.rename` (POSIX atomic). Closes P1#3 above as a side-effect.

### Test totals

- load/test: 50 tests (+8 since round 1). 1 flaky at high frequency, 1 flaky at low frequency.
- adapters/rails/test: 21 tests (+2). 2 skipped (integration, opt-in).
- workloads/missing_index_todos/test: 8 tests. All pass.

### Eng Review — Critical gaps resolved

All 3 critical gaps from round 1 are closed:
- `metrics.jsonl` produced by production path.
- `adapter-commands.jsonl` produced by production path.
- SIGINT/SIGTERM cooperatively stop the runner and trigger ensure-cleanup.


## GSTACK REVIEW REPORT — Round 3 (2026-04-22)

Re-review after commit `4e08407` on top of `5e385ce`.

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| Codex Review | `/codex review` (outside voice) | Independent 2nd opinion | 3 | SHIP WITH FIXES | 3 of 4 residuals fully FIXED. Residual #1 PARTIALLY FIXED — top-level key names now match spec but `args` semantics still drift. |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 3 | SHIP WITH FIXES | 3 of 4 R2 residuals fully FIXED; 1 narrow residual on `args` payload content. |

**VERDICT:** SHIP WITH FIXES — one narrow-scope spec drift remains. Not a blocker but should be resolved before merge (pick one: strip `["--json", subcommand]` from args, OR update spec §9.2 to reflect implementation).

### Round-2 residuals — status

1. ⚠️ **PARTIALLY FIXED: adapter-commands.jsonl spec drift** — field names now correct (`ts, command, args, exit_code, duration_ms, stdout_json, stderr`) at `load/lib/load/adapter_client.rb:53-60`, `:66-74`. BUT `args` still includes `--json` and the subcommand name: `["--json", "prepare", "--app-root", "..."]` vs spec §9.2 example `["--app-root", "/..."]`. Test asserts the drifted shape at `load/test/adapter_client_test.rb:35`. Fix: `args: argv[1..]` (strip subcommand) or update spec.

2. ✅ **FIXED: zero-seed flake** — `load/test/runner_test.rb:231-249` replaces `AdvancingClock` + `Thread.pass` with `Time.now.utc` + bounded `sleep(min(seconds, 0.001))` + `Timeout.timeout(1.0)` wrapper. 8/8 full-suite runs passed locally (previously 6/8 failed). Codex independently confirmed 20/20 isolated and 10/10 file-level passes.

3. ✅ **FIXED: sigterm-test flake** — root cause was non-atomic `run.json` writes (resolved by #4). Test at `load/test/cli_test.rb:170-206` no longer observes partial JSON. 8/8 full-suite runs include this test and all passed.

4. ✅ **FIXED: non-atomic run.json writes** — `load/lib/load/run_record.rb:27-30` now writes to `run.json.tmp` then `File.rename`. Regression test `load/test/run_record_test.rb:37-67` spins a reader thread against 50 concurrent 5MB-payload writes and asserts no partial reads. Codex confirmed the atomic-replace on source inspection.

### New findings (round 3)

None. The one remaining issue is the narrow `args` semantics residue of residual #1.

### Test totals (round 3)

- load/test: **51 tests** (+1 new `test_write_run_never_exposes_partial_json_to_concurrent_readers`). 8/8 full-suite runs clean.
- adapters/rails/test: 21 tests (2 skipped, opt-in integration).
- workloads/missing_index_todos/test: 8 tests.
- **All green. Zero flakes observed across 8 consecutive full-suite runs.**


## Round 4 — Ship Review Follow-Up (2026-04-24)

Addressed the `DO_NOT_SHIP` findings from `docs/superpowers/plans/2026-04-23-load-runner-ship-review.md`.

### What moved

- P0.2: `Load::RateLimiter` now reserves future slots under the mutex and sleeps after releasing it. Coverage now includes a wall-clock overlap test so multi-worker serialization cannot hide behind the fake sleeper.
- P0.3: worker traffic now uses a started `Load::Client` per worker and closes it in `ensure`, so the request hot path reuses one connection instead of reconnecting for every request.
- P0.1: `RailsAdapter::TemplateCache` now keys template databases by schema digest plus the full seed-time environment, including `SEED`, so clone hits cannot silently restore the wrong dataset.
- P1.1: request totals moved into each worker-owned `TrackingBuffer` and are aggregated when the runner writes outcome state; the shared runner mutex is no longer on every request counter increment.
- P2.1: `Reporter` now writes the actual elapsed `interval_ms` for the final tail flush.
- P2.2: `TemplateCache` now rejects invalid Postgres database identifiers before interpolating them into SQL.
- P2.3: `adapter-commands.jsonl` now redacts sensitive env-style keys and URL credentials before writing logged args or stderr.
- P2.4: the spec now matches the implemented contract for `migrate`, `reset-state --workload`, `query_ids`, `schema_version`, and `outcome.error_code`; `--debug-log` was removed from the spec rather than implemented.
- P2.5: `reset-state` now reuses the existing `LoadDataset` command for seed loading while preserving its explicit full-reset `db:drop` step.
- P2.6: stale temporal wording referencing the removed fixture harness was removed from surviving docs/comments.

### Deferred

- P3 items remain deferred for a follow-up cleanup pass. Nothing from the P3 bucket was bundled into this round.
