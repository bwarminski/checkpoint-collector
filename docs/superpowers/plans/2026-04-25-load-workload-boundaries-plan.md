# Load Workload Boundaries Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor `Load::Scale` and `Load::Runner` so workload-specific env knobs, invariant SQL, and invariant threshold logic live with `missing-index-todos` instead of the generic core.

**Architecture:** Keep `rows_per_table` on `Load::Scale`, replace fixed scale knobs with `extra`, and make invariant sampling a workload hook that returns generic `InvariantSample(checks)` data. `Load::Runner` continues to orchestrate sampling, warning persistence, and abort behavior, but no longer knows about the `todos` table, `open_count`, or missing-index threshold ratios.

**Tech Stack:** Ruby, Minitest, `Data.define`, `PG`, existing `Load::Runner` / `Load::Workload` / Rails adapter code paths

---

## File Map

**Create:**
- `workloads/missing_index_todos/invariant_sampler.rb` — workload-owned PG sampler for missing-index counts and thresholds.
- `workloads/missing_index_todos/test/invariant_sampler_test.rb` — sampler-focused tests moved out of `load/test/runner_test.rb`.
- `docs/superpowers/plans/2026-04-25-load-workload-boundaries-plan.md` — this plan.

**Modify:**
- `load/lib/load/scale.rb` — replace `open_fraction` with `extra` and tighten `env_pairs`.
- `load/lib/load/workload.rb` — add `invariant_sampler(database_url:, pg:)` defaulting to `nil`.
- `load/lib/load/runner.rb` — add generic `InvariantCheck`, reshape `InvariantSample`, remove nested sampler/default threshold logic, and resolve samplers through the workload hook.
- `workloads/missing_index_todos/workload.rb` — move workload env knob into `extra` and expose `invariant_sampler`.
- `load/test/scale_test.rb` — lock the new scale contract.
- `load/test/adapter_client_test.rb` — verify reset-state still emits `OPEN_FRACTION` through `extra`.
- `load/test/cli_test.rb` — remove generic `open_fraction` construction noise.
- `load/test/workload_registry_test.rb` — remove generic `open_fraction` construction noise.
- `load/test/runner_test.rb` — convert invariant tests to generic checks, remove nested sampler coverage, and keep orchestration coverage.
- `workloads/missing_index_todos/test/workload_test.rb` — assert the workload scale uses `extra` and returns the workload sampler hook.
- `workloads/missing_index_todos/README.md` — update documented scale shape if it still references `open_fraction` as a first-class scale field.
- `JOURNAL.md` — record the implementation contract and validation notes.

**Verify Against:**
- `docs/superpowers/specs/2026-04-25-load-workload-boundaries-design.md`
- `adapters/rails/lib/rails_adapter/commands/load_dataset.rb`
- `adapters/rails/test/fixtures/demo_app/db/seeds.rb`

## Task 1: Convert `Load::Scale` To `extra`

**Files:**
- Modify: `load/test/scale_test.rb`
- Modify: `load/lib/load/scale.rb`
- Modify: `load/test/adapter_client_test.rb`
- Modify: `load/test/cli_test.rb`
- Modify: `load/test/workload_registry_test.rb`
- Modify: `load/test/runner_test.rb`
- Modify: `workloads/missing_index_todos/workload.rb`
- Modify: `workloads/missing_index_todos/test/workload_test.rb`

- [ ] **Step 1: Write the failing scale and call-site tests**

Replace the current scale test with focused coverage in `load/test/scale_test.rb`:

```ruby
def test_scale_defaults_extra_to_empty_hash
  scale = Load::Scale.new(rows_per_table: 10)

  assert_equal({}, scale.extra)
end

def test_env_pairs_upcases_extra_keys_and_always_emits_rows_per_table
  scale = Load::Scale.new(rows_per_table: 10, seed: 7, extra: { open_fraction: 0.6, batch_size: 25 })

  assert_equal(
    {
      "OPEN_FRACTION" => 0.6,
      "BATCH_SIZE" => 25,
      "ROWS_PER_TABLE" => "10",
    },
    scale.env_pairs,
  )
end

def test_env_pairs_excludes_seed
  scale = Load::Scale.new(rows_per_table: 10, seed: 99, extra: {})

  refute_includes scale.env_pairs.keys, "SEED"
end
```

Update the scale expectations in `load/test/adapter_client_test.rb` and `workloads/missing_index_todos/test/workload_test.rb` to use:

```ruby
Load::Scale.new(rows_per_table: 10_000_000, extra: { open_fraction: 0.002 }, seed: 42)
Load::Scale.new(rows_per_table: 100_000, extra: { open_fraction: 0.6 }, seed: 42)
```

Drop `open_fraction: 0.0` from generic test workloads in `load/test/cli_test.rb`, `load/test/workload_registry_test.rb`, and `load/test/runner_test.rb`.

- [ ] **Step 2: Run the narrow test files to verify failure**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/scale_test.rb
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/adapter_client_test.rb
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby workloads/missing_index_todos/test/workload_test.rb
```

Expected: FAIL because `Load::Scale` still exposes `open_fraction` and does not have `extra`.

- [ ] **Step 3: Implement the minimal `Scale` and call-site changes**

Update `load/lib/load/scale.rb`:

```ruby
module Load
  Scale = Data.define(:rows_per_table, :seed, :extra) do
    def initialize(rows_per_table:, seed: 42, extra: {})
      super
    end

    def env_pairs
      extra.transform_keys { |key| key.to_s.upcase }
           .merge("ROWS_PER_TABLE" => rows_per_table.to_s)
    end
  end
end
```

Update `workloads/missing_index_todos/workload.rb`:

```ruby
def scale
  Load::Scale.new(rows_per_table: 100_000, extra: { open_fraction: 0.6 }, seed: 42)
end
```

Leave `adapters/rails/test/fixtures/demo_app/db/seeds.rb` unchanged so it keeps reading `OPEN_FRACTION` from env.

- [ ] **Step 4: Re-run the narrow tests to verify they pass**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/scale_test.rb
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/adapter_client_test.rb
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/cli_test.rb
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/workload_registry_test.rb
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby workloads/missing_index_todos/test/workload_test.rb
```

Expected: PASS.

- [ ] **Step 5: Commit the scale slice**

```bash
git add load/lib/load/scale.rb load/test/scale_test.rb load/test/adapter_client_test.rb load/test/cli_test.rb load/test/workload_registry_test.rb load/test/runner_test.rb workloads/missing_index_todos/workload.rb workloads/missing_index_todos/test/workload_test.rb
git commit -m "refactor: move workload env knobs into scale extra"
```

## Task 2: Add Generic Invariant Value Types And Workload Hook

**Files:**
- Modify: `load/test/runner_test.rb`
- Modify: `load/lib/load/runner.rb`
- Modify: `load/lib/load/workload.rb`
- Modify: `workloads/missing_index_todos/test/workload_test.rb`

- [ ] **Step 1: Write the failing invariant-value tests**

Add focused tests near the invariant section of `load/test/runner_test.rb`:

```ruby
def test_invariant_check_reports_min_and_max_breaches
  check = Load::Runner::InvariantCheck.new("total_count", 250, 300, 200)

  assert_equal [
    "total_count 250 is below min 300",
    "total_count 250 is above max 200",
  ], check.breaches
  assert_equal true, check.breach?
end

def test_invariant_sample_aggregates_check_records_for_warning_and_run_json
  sample = Load::Runner::InvariantSample.new(
    [
      Load::Runner::InvariantCheck.new("open_count", 100, 300, nil),
      Load::Runner::InvariantCheck.new("total_count", 1000, 800, 1200),
    ],
  )

  assert_equal true, sample.breach?
  assert_equal 2, sample.to_warning.fetch(:checks).length
  assert_equal 2, sample.to_record(sampled_at: Time.utc(2026, 4, 25, 0, 0, 0)).fetch(:checks).length
end

def test_workload_invariant_sampler_defaults_to_nil
  assert_nil Load::Workload.new.invariant_sampler(database_url: "postgres://example.test/db", pg: Object.new)
end
```

Add a workload hook expectation to `workloads/missing_index_todos/test/workload_test.rb`:

```ruby
def test_workload_builds_a_missing_index_invariant_sampler
  workload = Load::Workloads::MissingIndexTodos::Workload.new
  sampler = workload.invariant_sampler(database_url: "postgres://example.test/checkpoint", pg: Object.new)

  assert_instance_of Load::Workloads::MissingIndexTodos::InvariantSampler, sampler
end
```

- [ ] **Step 2: Run the runner and workload test files to confirm failure**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby workloads/missing_index_todos/test/workload_test.rb
```

Expected: FAIL because `InvariantCheck` does not exist and `Load::Workload` has no `invariant_sampler` method.

- [ ] **Step 3: Implement the generic invariant contract and workload hook**

Update `load/lib/load/workload.rb`:

```ruby
def invariant_sampler(database_url:, pg:)
  nil
end
```

Replace the invariant value objects in `load/lib/load/runner.rb`:

```ruby
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
```

Do not change the invariant thread control flow yet.

- [ ] **Step 4: Re-run the narrow tests to verify they pass**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb --name test_invariant_check_reports_min_and_max_breaches
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb --name test_invariant_sample_aggregates_check_records_for_warning_and_run_json
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb --name test_workload_invariant_sampler_defaults_to_nil
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby workloads/missing_index_todos/test/workload_test.rb --name test_workload_builds_a_missing_index_invariant_sampler
```

Expected: the runner value-object tests pass; the workload sampler test still fails until Task 3 lands.

- [ ] **Step 5: Commit the generic invariant contract slice**

```bash
git add load/lib/load/workload.rb load/lib/load/runner.rb load/test/runner_test.rb workloads/missing_index_todos/test/workload_test.rb
git commit -m "refactor: make invariant samples generic"
```

## Task 3: Extract The Missing-Index Sampler

**Files:**
- Create: `workloads/missing_index_todos/invariant_sampler.rb`
- Create: `workloads/missing_index_todos/test/invariant_sampler_test.rb`
- Modify: `workloads/missing_index_todos/workload.rb`
- Modify: `workloads/missing_index_todos/test/workload_test.rb`
- Modify: `load/test/runner_test.rb`

- [ ] **Step 1: Write the failing sampler tests**

Create `workloads/missing_index_todos/test/invariant_sampler_test.rb` with:

```ruby
# ABOUTME: Verifies the missing-index invariant sampler queries workload-owned counts.
# ABOUTME: Covers the isolated PG connection and generic invariant sample output.
require_relative "../../../load/test/test_helper"
require_relative "../invariant_sampler"

class MissingIndexTodosInvariantSamplerTest < Minitest::Test
  def test_sampler_uses_isolated_pg_connection_and_returns_named_checks
    pg = FakePg.new(open_count: 35_000, total_count: 100_000)
    sampler = Load::Workloads::MissingIndexTodos::InvariantSampler.new(
      pg:,
      database_url: "postgres://localhost/checkpoint_collector",
      open_floor: 30_000,
      total_floor: 80_000,
      total_ceiling: 200_000,
    )

    sample = sampler.call

    refute pg.shared_connection_used?
    assert_equal true, pg.connection.closed?
    assert_includes pg.connection.session_sql, "SET LOCAL pg_stat_statements.track = 'none'"
    assert_equal ["open_count", "total_count"], sample.checks.map(&:name)
    assert_equal true, sample.healthy?
  end
end
```

Move the `FakePg` and `FakePgConnection` helpers out of `load/test/runner_test.rb` into this sampler test file unless another generic test still needs them.

Add a workload test that asserts threshold math:

```ruby
def test_workload_sampler_uses_rows_per_table_thresholds
  workload = Load::Workloads::MissingIndexTodos::Workload.new
  sampler = workload.invariant_sampler(database_url: "postgres://example.test/checkpoint", pg: Object.new)

  assert_equal 30_000, sampler.instance_variable_get(:@open_floor)
  assert_equal 80_000, sampler.instance_variable_get(:@total_floor)
  assert_equal 200_000, sampler.instance_variable_get(:@total_ceiling)
end
```

- [ ] **Step 2: Run the sampler-focused tests to confirm failure**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby workloads/missing_index_todos/test/invariant_sampler_test.rb
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby workloads/missing_index_todos/test/workload_test.rb
```

Expected: FAIL because the sampler file does not exist and the workload does not build it.

- [ ] **Step 3: Implement the workload sampler and workload hook**

Create `workloads/missing_index_todos/invariant_sampler.rb`:

```ruby
# ABOUTME: Samples missing-index todo counts for continuous-run invariant checks.
# ABOUTME: Owns the todos SQL and emits generic runner invariant checks.
module Load
  module Workloads
    module MissingIndexTodos
      class InvariantSampler
        OPEN_COUNT_SQL = "SELECT COUNT(*) AS count FROM todos WHERE status = 'open'".freeze
        TOTAL_COUNT_SQL = "SELECT reltuples::bigint AS count FROM pg_class WHERE relname = 'todos'".freeze

        def initialize(pg:, database_url:, open_floor:, total_floor:, total_ceiling:)
          @pg = pg
          @database_url = database_url
          @open_floor = open_floor
          @total_floor = total_floor
          @total_ceiling = total_ceiling
        end

        def call
          with_connection do |connection|
            connection.transaction do |txn|
              txn.exec("SET LOCAL pg_stat_statements.track = 'none'")
              open_count = txn.exec(OPEN_COUNT_SQL).first.fetch("count").to_i
              total_count = txn.exec(TOTAL_COUNT_SQL).first.fetch("count").to_i

              Load::Runner::InvariantSample.new(
                [
                  Load::Runner::InvariantCheck.new("open_count", open_count, @open_floor, nil),
                  Load::Runner::InvariantCheck.new("total_count", total_count, @total_floor, @total_ceiling),
                ],
              )
            end
          end
        end

        private

        def with_connection
          connection = @pg.connect(@database_url)
          yield connection
        ensure
          connection&.close
        end
      end
    end
  end
end
```

Update `workloads/missing_index_todos/workload.rb` to require the sampler and implement:

```ruby
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
```

Delete the old sampler-specific test from `load/test/runner_test.rb`.

- [ ] **Step 4: Re-run the sampler and workload tests to verify they pass**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby workloads/missing_index_todos/test/invariant_sampler_test.rb
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby workloads/missing_index_todos/test/workload_test.rb
```

Expected: PASS.

- [ ] **Step 5: Commit the sampler extraction slice**

```bash
git add workloads/missing_index_todos/invariant_sampler.rb workloads/missing_index_todos/test/invariant_sampler_test.rb workloads/missing_index_todos/workload.rb workloads/missing_index_todos/test/workload_test.rb load/test/runner_test.rb
git commit -m "refactor: move missing-index invariant sampler into workload"
```

## Task 4: Resolve Invariant Samplers Through The Workload Hook

**Files:**
- Modify: `load/test/runner_test.rb`
- Modify: `load/lib/load/runner.rb`

- [ ] **Step 1: Write the failing runner integration tests**

Add two focused tests to `load/test/runner_test.rb`:

```ruby
def test_runner_asks_workload_for_invariant_sampler_in_continuous_mode
  workload = HookedInvariantWorkload.new
  runner = Load::Runner.new(
    workload:,
    adapter_client: FakeAdapterClient.new,
    run_record: FakeRunRecord.new,
    clock: fake_clock,
    sleeper: ->(*) { Thread.pass },
    http: FakeHttp.new,
    readiness_path: nil,
    startup_grace_seconds: 0.0,
    mode: :continuous,
    database_url: "postgres://example.test/checkpoint",
    pg: :fake_pg,
  )

  assert_instance_of FakeInvariantSampler, runner.instance_variable_get(:@invariant_sampler)
  assert_equal ["postgres://example.test/checkpoint", :fake_pg], workload.invariant_sampler_args
end

def test_runner_requires_workload_sampler_for_continuous_mode
  error = assert_raises(Load::AdapterClient::AdapterError) do
    Load::Runner.new(
      workload: MetricsWorkload.new,
      adapter_client: FakeAdapterClient.new,
      run_record: FakeRunRecord.new,
      clock: fake_clock,
      sleeper: ->(*) { Thread.pass },
      http: FakeHttp.new,
      readiness_path: nil,
      startup_grace_seconds: 0.0,
      mode: :continuous,
      database_url: nil,
    )
  end

  assert_equal "continuous mode requires the workload to provide an invariant sampler", error.message
end
```

Convert existing invariant sample construction in `load/test/runner_test.rb` from:

```ruby
Load::Runner::InvariantSample.new(open_count: 100, total_count: 10_000, open_floor: 30_000, total_floor: 80_000, total_ceiling: 200_000)
```

to:

```ruby
Load::Runner::InvariantSample.new(
  [
    Load::Runner::InvariantCheck.new("open_count", 100, 30_000, nil),
    Load::Runner::InvariantCheck.new("total_count", 10_000, 80_000, 200_000),
  ],
)
```

- [ ] **Step 2: Run the runner test file to confirm failure**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb
```

Expected: FAIL because `Load::Runner` still builds the nested default sampler and old sample shape.

- [ ] **Step 3: Implement runner-side sampler resolution**

Update `load/lib/load/runner.rb` initialization:

```ruby
@invariant_sampler = invariant_sampler || @workload.invariant_sampler(database_url:, pg:)
if @mode == :continuous && @invariant_sampler.nil?
  raise AdapterClient::AdapterError, "continuous mode requires the workload to provide an invariant sampler"
end
```

Delete:

```ruby
class InvariantSampler
  ...
end

def default_invariant_sampler(database_url:, pg:)
  ...
end
```

Keep the invariant thread, `sample_invariants`, warning persistence, and breach-counting logic unchanged except for working with the new `InvariantSample` shape.

Add a runner test helper workload:

```ruby
class HookedInvariantWorkload < MetricsWorkload
  attr_reader :invariant_sampler_args

  def invariant_sampler(database_url:, pg:)
    @invariant_sampler_args = [database_url, pg]
    FakeInvariantSampler.new([])
  end
end
```

- [ ] **Step 4: Re-run the runner tests to verify they pass**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb
```

Expected: PASS.

- [ ] **Step 5: Commit the runner integration slice**

```bash
git add load/lib/load/runner.rb load/test/runner_test.rb
git commit -m "refactor: resolve invariant samplers through workloads"
```

## Task 5: Documentation And Full Validation Gate

**Files:**
- Modify: `workloads/missing_index_todos/README.md`
- Modify: `JOURNAL.md`

- [ ] **Step 1: Update workload docs if they still describe the old scale shape**

If `workloads/missing_index_todos/README.md` still describes `open_fraction` as a direct scale field, update it to describe the workload env knob through `scale.extra` while keeping the runtime env name `OPEN_FRACTION`.

Use wording like:

```md
- `rows_per_table: 10_000_000`
- `extra: { open_fraction: 0.002 }`
```

- [ ] **Step 2: Run the full automated test suites**

Run:

```bash
make test
```

Expected: `load`, `adapters`, and `workloads` suites all pass.

- [ ] **Step 3: Run the 50x stability gate on the relocated invariant breach test**

Run:

```bash
for i in $(seq 1 50); do
  BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby workloads/missing_index_todos/test/invariant_sampler_test.rb --name test_sampler_uses_isolated_pg_connection_and_returns_named_checks
done | sort -u
```

Expected:

```text
1 runs, 0 failures, 0 errors, 0 skips
```

If that test proves too narrow compared with the original flaky path, switch the loop to the runner-side continuous breach test that now consumes the relocated sampler contract and record the exact command in `JOURNAL.md`.

- [ ] **Step 4: Run the live finite workload path and oracle**

Run:

```bash
bin/load run --workload missing-index-todos --adapter ./bin/rails-adapter --app-root /home/bjw/db-specialist-demo --mode finite --duration 60
```

Then inspect the latest run with the existing oracle entrypoint:

```bash
ruby workloads/missing_index_todos/oracle.rb runs/<latest-run-dir>
```

Expected: run completes successfully and oracle prints `PASS`.

- [ ] **Step 5: Run the leak checks**

Run:

```bash
grep -r "open_fraction" load/lib load/test/runner_test.rb load/test/cli_test.rb
grep -rn "todos" load/lib/
```

Expected: both commands print nothing.

- [ ] **Step 6: Record validation notes and commit the final slice**

Add a `JOURNAL.md` entry summarizing:

- the generic `InvariantCheck` / `InvariantSample` contract
- that `missing-index-todos` now owns invariant SQL and thresholds
- the exact validation commands that passed

Then commit:

```bash
git add workloads/missing_index_todos/README.md JOURNAL.md
git commit -m "docs: record workload boundary refactor validation"
```

## Self-Review

- Spec coverage: Task 1 covers the `Scale` shape and call-site sweep, Task 2 covers the generic invariant contract and base workload hook, Task 3 covers sampler extraction and workload-owned threshold math, Task 4 covers runner integration and error handling, and Task 5 covers validation and leak checks.
- Placeholder scan: every task names exact files, commands, and target code shapes; there are no `TODO` or `TBD` placeholders.
- Type consistency: the plan consistently uses `Load::Runner::InvariantCheck.new(name, actual, min, max)`, `Load::Runner::InvariantSample.new([checks])`, and `Load::Workload#invariant_sampler(database_url:, pg:)`.
