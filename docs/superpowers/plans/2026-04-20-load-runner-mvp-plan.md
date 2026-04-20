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

- [ ] **Step 3: Implement the minimal value objects, base classes, and pure utilities**

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

# load/lib/load/rate_limiter.rb
module Load
  class RateLimiter
    def initialize(rate_limit:, clock:, sleeper:)
      @rate_limit = rate_limit
      @clock = clock
      @sleeper = sleeper
      @mutex = Mutex.new
      @next_allowed_at = nil
    end

    def wait_turn
      return if @rate_limit == :unlimited

      @mutex.synchronize do
        now = @clock.call
        @next_allowed_at ||= now
        sleep_for = @next_allowed_at - now
        @sleeper.call(sleep_for) if sleep_for.positive?
        @next_allowed_at = [@next_allowed_at, now].max + (1.0 / @rate_limit)
      end
    end
  end
end
```

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

- [ ] **Step 1: Write the failing metrics and worker tests**

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

# load/test/worker_test.rb
def test_worker_records_errors_without_raising
  selector = stub(next: Load::ActionEntry.new(FailingAction, 1))
  buffer = Load::Metrics::Buffer.new
  worker = Load::Worker.new(worker_id: 2, selector:, buffer:, client: Object.new, ctx: { base_url: "http://127.0.0.1:3000" }, rng: Random.new(7), rate_limiter: stub(wait_turn: nil), stop_flag: stop_after(1))

  worker.run

  assert_equal 1, buffer.swap!.fetch(:failing_action).fetch(:errors_by_class).fetch("RuntimeError")
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
        @rate_limiter.wait_turn
        entry = @selector.next
        action = entry.action_class.new(rng: @rng, ctx: @ctx, client: @client)
        started_ns = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
        response = action.call
        @buffer.record_ok(action: action.name, latency_ns: elapsed_ns(started_ns), status: response.code.to_i)
      rescue StandardError => error
        @buffer.record_error(action: action&.name || :unknown, latency_ns: elapsed_ns(started_ns), error_class: error.class.name)
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

# load/test/cli_test.rb
def test_run_command_exits_three_when_no_successful_requests
  status = run_bin_load("run", "--workload", fixture_workload_path, "--adapter", "fake-adapter", "--app-root", "/tmp/demo", runner: FakeRunner.new(exit_code: 3))
  assert_equal 3, status
end
```

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
  exit Load::CLI.new(argv: ARGV, stdout: $stdout, stderr: $stderr).run
end

warn "usage: bin/load run --workload PATH --adapter PATH --app-root PATH"
exit 2
```

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
```

- [ ] **Step 2: Run the adapter unit tests to verify they fail**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby adapters/rails/test/load_dataset_test.rb`
Expected: `RailsAdapter` is undefined.

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby adapters/rails/test/reset_state_test.rb`
Expected: `RailsAdapter::Commands::ResetState` is undefined.

- [ ] **Step 3: Implement the adapter command classes and the JSON CLI**

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

```ruby
def test_prepare_migrate_load_start_and_stop_against_fixture_app
  skip if ENV["SKIP_RAILS_INTEGRATION"] == "1"

  app_root = File.expand_path("fixtures/demo_app", __dir__)
  adapter = bench_adapter_bin

  assert_command_ok adapter, "prepare", "--app-root", app_root
  assert_command_ok adapter, "migrate", "--app-root", app_root
  assert_command_ok adapter, "load-dataset", "--app-root", app_root, "--workload", "demo", "--seed", "7", "--env", "ROWS_PER_TABLE=10", "--env", "OPEN_FRACTION=0.2"
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
  assert_equal 4, workload.load_plan.workers
  assert_equal :unlimited, workload.load_plan.rate_limit
end

# workloads/missing_index_todos/test/oracle_test.rb
def test_oracle_fails_when_plan_relation_node_is_not_seq_scan
  oracle = Load::Workloads::MissingIndexTodos::Oracle.new(pg: fake_pg_with_plan("Index Scan"), clickhouse_query: ->(*) { { "calls" => "600", "mean_ms" => "3.9" } }, sleeper: ->(*) {})

  error = assert_raises(SystemExit) { oracle.run([fixture_run_dir]) }
  assert_equal 1, error.status
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
        Load::LoadPlan.new(workers: 4, duration_seconds: 60, rate_limit: :unlimited, seed: nil)
      end
    end
  end
end
```

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

### Task 8: Remove the Fixture Harness and Toy Harness

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

- [ ] **Step 1: Delete the old harness files only after the replacement path is green**

```bash
rm bin/fixture
rm -r collector/lib/fixtures collector/test/fixtures fixtures/missing-index
rm load/harness.rb load/test/harness_test.rb load/README.md fixture-harness-walkthrough.md
```

- [ ] **Step 2: Run the replacement test suites to prove nothing still depends on the deleted code**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/rate_limiter_test.rb`
Expected: PASS

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/metrics_test.rb`
Expected: PASS

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb`
Expected: PASS

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby adapters/rails/test/integration_test.rb`
Expected: PASS or `skip` when `SKIP_RAILS_INTEGRATION=1`.

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby workloads/missing_index_todos/test/oracle_test.rb`
Expected: PASS

- [ ] **Step 3: Commit the deletions**

```bash
git add bin/fixture collector/lib/fixtures collector/test/fixtures fixtures/missing-index load/harness.rb load/test/harness_test.rb load/README.md fixture-harness-walkthrough.md JOURNAL.md
git commit -m "refactor: replace fixture harness with load runner"
```

### Task 9: End-to-End Verification and Parity Check

**Files:**
- Modify: `JOURNAL.md`

- [ ] **Step 1: Bring up the collector stack from a clean state**

Run: `docker compose down -v`
Expected: existing Postgres, ClickHouse, and collector containers stop and volumes are removed.

Run: `docker compose up -d --build postgres clickhouse collector`
Expected: all three services report healthy or running.

- [ ] **Step 2: Run the full Ruby test surface**

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

- [ ] **Step 3: Verify parity against the current `db-specialist-demo` default branch**

Run: `bin/load run --workload workloads/missing_index_todos/workload.rb --adapter adapters/rails/bin/bench-adapter --app-root /home/bjw/db-specialist-demo`
Expected: exit `0`, create `runs/<timestamp>-missing-index-todos/`, and report at least one successful request.

Run: `ruby workloads/missing_index_todos/oracle.rb "$(ls -dt runs/*-missing-index-todos | head -n1)"`
Expected: prints `PASS: explain` and `PASS: clickhouse`, then exits `0`.

- [ ] **Step 4: Verify the oracle flips on `oracle/add-index`**

Run: `git -C /home/bjw/db-specialist-demo checkout oracle/add-index`
Expected: worktree switches to the oracle tag without local changes.

Run: `bin/load run --workload workloads/missing_index_todos/workload.rb --adapter adapters/rails/bin/bench-adapter --app-root /home/bjw/db-specialist-demo`
Expected: exit `0`, new run record written.

Run: `ruby workloads/missing_index_todos/oracle.rb "$(ls -dt runs/*-missing-index-todos | head -n1)"`
Expected: prints `FAIL: explain (expected Seq Scan, got Index Scan)` and exits `1`.

Run: `git -C /home/bjw/db-specialist-demo checkout master`
Expected: demo app returns to the default branch for future work.

- [ ] **Step 5: Record the exact verification output and commit**

```bash
git add JOURNAL.md
git commit -m "test: verify load runner parity"
```

## Self-Review

- Spec coverage:
  - `/load` runner modules and run record: Tasks 1-3
  - Rails adapter contract and template caching: Tasks 4-5
  - `missing-index-todos` workload and tactical oracle: Task 6
  - `bin/load`, docs, smoke target: Tasks 3 and 7
  - required deletions: Task 8
  - parity verification against current demo app and `oracle/add-index`: Task 9
  - external `db-specialist-demo` seed dependency: Cross-Repo Dependency section and Task 5
- Placeholder scan:
  - No `TODO`, `TBD`, or “similar to” placeholders remain.
- Type consistency:
  - `Scale` fields stay `rows_per_table`, `open_fraction`, `seed`.
  - `LoadPlan` fields stay `workers`, `duration_seconds`, `rate_limit`, `seed`.
  - Adapter commands stay exactly `describe`, `prepare`, `migrate`, `load-dataset`, `reset-state`, `start`, `stop`.
