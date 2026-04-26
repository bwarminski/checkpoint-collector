# Runner Constructor Grouping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Regroup `Load::Runner` constructor inputs into `Runtime`, `Config`, and `InvariantConfig` value objects without changing runtime behavior.

**Architecture:** Keep `Load::Runner` as the top-level coordinator, but replace the long flat constructor signature with three domain-shaped config objects. `Runner` will still build `RunState` and `InvariantMonitor`, but it will resolve and validate invariant setup through small helper methods instead of inline constructor logic.

**Tech Stack:** Ruby, Minitest, `Data.define`, existing `Load::Runner` / `Load::CLI` / workload APIs.

---

## File Map

- Modify: `load/lib/load/runner.rb`
  - Add `Runtime.default`, replace `Settings` with `Config`, add `InvariantConfig`, regroup constructor inputs, and move invariant setup into helpers.
- Modify: `load/lib/load/cli.rb`
  - Construct `Runtime`, `Config`, and `InvariantConfig` explicitly before building `Load::Runner`.
- Modify: `load/test/runner_test.rb`
  - Add focused constructor-grouping regression tests and keep existing runner behavior locks green.
- Modify: `load/test/cli_test.rb`
  - Lock the new `Runner.new` calling convention from the CLI side.
- Modify: `JOURNAL.md`
  - Record the constructor grouping decision and any verification findings.

## Task 1: Add Constructor Grouping Tests

**Files:**
- Modify: `load/test/runner_test.rb`
- Modify: `load/test/cli_test.rb`

- [ ] **Step 1: Write the failing runner constructor tests**

Add these tests near the other constructor-focused cases in `load/test/runner_test.rb`:

```ruby
def test_runtime_default_provides_clock_sleeper_http_and_stop_flag
  runtime = Load::Runner::Runtime.default

  assert_respond_to runtime.clock, :call
  assert_respond_to runtime.sleeper, :call
  assert_equal Net::HTTP, runtime.http
  assert_instance_of Load::Runner::InternalStopFlag, runtime.stop_flag
end

def test_config_defaults_match_existing_runner_defaults
  config = Load::Runner::Config.new

  assert_equal "/up", config.readiness_path
  assert_equal 15, config.startup_grace_seconds
  assert_equal 5, config.metrics_interval_seconds
  assert_nil config.workload_file
  assert_nil config.app_root
  assert_nil config.adapter_bin
  assert_equal :finite, config.mode
  assert_nil config.verifier
end

def test_invariant_config_defaults_match_existing_runner_defaults
  config = Load::Runner::InvariantConfig.new

  assert_equal :enforce, config.policy
  assert_nil config.sampler
  assert_equal Load::Runner::DEFAULT_INVARIANT_SAMPLE_INTERVAL_SECONDS, config.sample_interval_seconds
  assert_equal ENV["DATABASE_URL"], config.database_url
  assert_equal PG, config.pg
end

def test_runner_uses_invariant_config_database_url_and_pg_when_resolving_sampler
  workload = RecordingSamplerWorkload.new

  Load::Runner.new(
    workload:,
    adapter_client: FakeAdapterClient.new,
    run_record: FakeRunRecord.new,
    runtime: Load::Runner::Runtime.new(fake_clock, ->(*) { Thread.pass }, FakeHttp.new, Load::Runner::InternalStopFlag.new),
    config: Load::Runner::Config.new(mode: :continuous, readiness_path: nil, startup_grace_seconds: 0.0),
    invariant_config: Load::Runner::InvariantConfig.new(database_url: "postgres://example.test/checkpoint", pg: :fake_pg),
  )

  assert_equal ["postgres://example.test/checkpoint", :fake_pg], workload.invariant_sampler_args
end

def test_runner_continuous_mode_validation_uses_grouped_configs
  error = assert_raises(Load::AdapterClient::AdapterError) do
    Load::Runner.new(
      workload: MetricsWorkload.new,
      adapter_client: FakeAdapterClient.new,
      run_record: FakeRunRecord.new,
      runtime: Load::Runner::Runtime.new(fake_clock, ->(*) { Thread.pass }, FakeHttp.new, Load::Runner::InternalStopFlag.new),
      config: Load::Runner::Config.new(mode: :continuous, readiness_path: nil, startup_grace_seconds: 0.0),
      invariant_config: Load::Runner::InvariantConfig.new(policy: :enforce, database_url: nil),
    )
  end

  assert_equal "continuous mode requires the workload to provide an invariant sampler", error.message
end
```

In `load/test/cli_test.rb`, add one test near the default runner-factory coverage:

```ruby
def test_default_runner_factory_builds_grouped_runner_dependencies
  calls = []
  runner_factory = lambda do |**kwargs|
    calls << kwargs
    Struct.new(:run).new(Load::ExitCodes::SUCCESS)
  end
  cli = Load::CLI.new(
    argv: ["run", "--workload", "missing-index-todos", "--adapter", "adapters/rails/bin/bench-adapter", "--app-root", "/tmp/demo"],
    version: "test",
    runner_factory:,
    stdout: StringIO.new,
    stderr: StringIO.new,
  )

  cli.run

  kwargs = calls.fetch(0)
  assert_instance_of Load::Runner::Runtime, kwargs.fetch(:runtime)
  assert_instance_of Load::Runner::Config, kwargs.fetch(:config)
  assert_instance_of Load::Runner::InvariantConfig, kwargs.fetch(:invariant_config)
end
```

- [ ] **Step 2: Run the focused tests and verify they fail**

Run:
```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb --name '/test_runtime_default_provides_clock_sleeper_http_and_stop_flag|test_config_defaults_match_existing_runner_defaults|test_invariant_config_defaults_match_existing_runner_defaults|test_runner_uses_invariant_config_database_url_and_pg_when_resolving_sampler|test_runner_continuous_mode_validation_uses_grouped_configs/'
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/cli_test.rb --name test_default_runner_factory_builds_grouped_runner_dependencies
```

Expected: failures for missing `Runtime.default`, missing `Config` / `InvariantConfig`, and old `Runner.new` keyword expectations.

- [ ] **Step 3: Implement the minimal constructor grouping in `Runner`**

In `load/lib/load/runner.rb`, replace the old constructor shape with grouped value objects. Add this near the top of the class, replacing `Settings`:

```ruby
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
```

Then change the constructor signature to:

```ruby
def initialize(workload:, adapter_client:, run_record:, runtime: Runtime.default, config: Config.new, invariant_config: InvariantConfig.new, stderr: $stderr)
```

Store:

```ruby
@workload = workload
@adapter_client = adapter_client
@runtime = runtime
@config = config
@invariant_config = invariant_config
@stderr = stderr
```

Replace the old inline sampler logic with helper calls:

```ruby
sampler = resolve_invariant_sampler
validate_invariant_sampler!(sampler)
```

Add these helpers below `private`:

```ruby
def resolve_invariant_sampler
  return @invariant_config.sampler if @invariant_config.policy == :off
  return @invariant_config.sampler if @invariant_config.sampler

  @workload.invariant_sampler(database_url: @invariant_config.database_url, pg: @invariant_config.pg)
end

def validate_invariant_sampler!(sampler)
  return unless @config.mode == :continuous
  return if @invariant_config.policy == :off
  return unless sampler.nil?

  raise AdapterClient::AdapterError, "continuous mode requires the workload to provide an invariant sampler"
end
```

Update all `@settings` / `@mode` / `@verifier` references in this file to use `@config`.

- [ ] **Step 4: Update CLI to build grouped objects**

In `load/lib/load/cli.rb`, update the default runner factory so it constructs grouped dependencies before calling `Load::Runner.new`:

```ruby
runtime = Load::Runner::Runtime.new(clock, sleeper, http, stop_flag)
config = Load::Runner::Config.new(
  readiness_path: readiness_path,
  startup_grace_seconds: startup_grace_seconds,
  metrics_interval_seconds: metrics_interval_seconds,
  workload_file: workload_file,
  app_root: app_root,
  adapter_bin: adapter_bin,
  mode: mode,
  verifier: verifier,
)
invariant_config = Load::Runner::InvariantConfig.new(
  policy: invariant_policy,
  sampler: invariant_sampler,
  sample_interval_seconds: invariant_sample_interval_seconds,
  database_url: database_url,
  pg: pg,
)

Load::Runner.new(
  workload: workload,
  adapter_client: adapter_client,
  run_record: run_record,
  runtime: runtime,
  config: config,
  invariant_config: invariant_config,
  stderr: stderr,
)
```

Do not change CLI behavior beyond the constructor call shape.

- [ ] **Step 5: Run focused tests and verify they pass**

Run:
```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb --name '/test_runtime_default_provides_clock_sleeper_http_and_stop_flag|test_config_defaults_match_existing_runner_defaults|test_invariant_config_defaults_match_existing_runner_defaults|test_runner_uses_invariant_config_database_url_and_pg_when_resolving_sampler|test_runner_continuous_mode_validation_uses_grouped_configs/'
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/cli_test.rb --name test_default_runner_factory_builds_grouped_runner_dependencies
```

Expected: all pass.

- [ ] **Step 6: Run unchanged regression locks**

Run:
```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb --name '/test_runner_aborts_after_three_consecutive_invariant_breaches|test_runner_warn_policy_records_breaches_without_aborting|test_runner_off_policy_skips_invariant_sampling|test_runner_records_invariant_breach_before_first_successful_request|test_runner_persists_invariant_samples_in_run_record|test_internal_stop_flag_preserves_first_reason/'
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/cli_test.rb
```

Expected: green, no behavior drift.

- [ ] **Step 7: Commit**

```bash
git add load/lib/load/runner.rb load/lib/load/cli.rb load/test/runner_test.rb load/test/cli_test.rb
git commit -m "refactor: group runner constructor inputs"
```

## Task 2: Remove Dead Flat-Constructor Scaffolding

**Files:**
- Modify: `load/lib/load/runner.rb`
- Modify: `JOURNAL.md`

- [ ] **Step 1: Write the failing cleanup lock tests**

In `load/test/runner_test.rb`, add one focused test proving `Runner` no longer depends on the old flat keyword surface:

```ruby
def test_runner_constructor_accepts_grouped_dependencies_only
  runner = Load::Runner.new(
    workload: MetricsWorkload.new,
    adapter_client: FakeAdapterClient.new,
    run_record: FakeRunRecord.new,
    runtime: Load::Runner::Runtime.new(fake_clock, ->(*) { Thread.pass }, FakeHttp.new, Load::Runner::InternalStopFlag.new),
    config: Load::Runner::Config.new(readiness_path: nil, startup_grace_seconds: 0.0),
    invariant_config: Load::Runner::InvariantConfig.new(policy: :off),
  )

  assert_instance_of Load::Runner, runner
end
```

This test is intentionally simple; the real lock is that all old call sites must already have been converted in Task 1.

- [ ] **Step 2: Run the focused cleanup test and verify it passes before cleanup**

Run:
```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb --name test_runner_constructor_accepts_grouped_dependencies_only
```

Expected: PASS.

- [ ] **Step 3: Delete dead flat-constructor compatibility code**

In `load/lib/load/runner.rb`, remove any remaining constructor-era remnants that only existed for the flat keyword API. After Task 1, the file should no longer reference:

- `Settings`
- old flat constructor keyword names inside `initialize`
- inline sampler/database validation logic in `initialize`

The final constructor should read like this shape:

```ruby
def initialize(workload:, adapter_client:, run_record:, runtime: Runtime.default, config: Config.new, invariant_config: InvariantConfig.new, stderr: $stderr)
  @workload = workload
  @adapter_client = adapter_client
  @runtime = runtime
  @config = config
  @invariant_config = invariant_config
  @stderr = stderr

  sampler = resolve_invariant_sampler
  validate_invariant_sampler!(sampler)

  @run_state = Load::RunState.new(...)
  @invariant_monitor = Load::InvariantMonitor.new(...)
end
```

Also remove `@run_record` if it is no longer needed after `RunState`/`LoadExecution` construction.

- [ ] **Step 4: Run targeted tests plus cleanup grep**

Run:
```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb --name test_runner_constructor_accepts_grouped_dependencies_only
grep -n "Settings\|readiness_path:\|startup_grace_seconds:\|metrics_interval_seconds:\|workload_file:\|app_root:\|adapter_bin:\|mode:\|verifier:\|invariant_policy:\|invariant_sampler:\|invariant_sample_interval_seconds:\|database_url:\|pg:" load/lib/load/runner.rb
```

Expected:
- test passes
- grep only finds these names in `Config` / `InvariantConfig` definitions or constructor calls into `RunState` / `InvariantMonitor`, not as old flat `initialize` kwargs

- [ ] **Step 5: Record the decision in the journal**

Append this note to `JOURNAL.md`:

```markdown
- 2026-04-25 constructor grouping refactor: `Load::Runner` now takes `runtime`, `config`, and `invariant_config` value objects; this keeps runtime seams, run settings, and invariant setup separate without introducing a factory or generic options hash.
```

- [ ] **Step 6: Commit**

```bash
git add load/lib/load/runner.rb load/test/runner_test.rb JOURNAL.md
git commit -m "refactor: simplify runner constructor"
```

## Task 3: Full Verification

**Files:**
- Modify: `JOURNAL.md` (only if verification reveals a non-obvious insight worth keeping)

- [ ] **Step 1: Run the full code-level suites**

Run:
```bash
make test
```

Expected:
- `load` green
- `adapters` green with the same 2 expected skips
- `workloads` green

- [ ] **Step 2: Run the constructor-focused stability loop**

Run:
```bash
for i in $(seq 1 20); do
  BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb \
    --name test_runner_aborts_after_three_consecutive_invariant_breaches 2>&1 | tail -3
  BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/invariant_monitor_test.rb \
    --name test_stop_unblocks_sleeping_thread 2>&1 | tail -3
done | grep -E "errors|failures" | sort -u
```

Expected: a single green line for each test shape, no failures or errors.

- [ ] **Step 3: Run cleanup greps**

Run:
```bash
grep -n "Settings = Data.define" load/lib/load/runner.rb
grep -n "def initialize(workload:, adapter_client:, run_record:, clock:, sleeper:" load/lib/load/runner.rb
```

Expected:
- no `Settings = Data.define`
- no old flat constructor signature

- [ ] **Step 4: Run diff and smoke sanity**

Run:
```bash
git diff --check
DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo BENCH_ADAPTER_PG_ADMIN_URL=postgres://postgres:postgres@localhost:5432/postgres bin/load run --workload missing-index-todos --adapter adapters/rails/bin/bench-adapter --app-root /home/bjw/db-specialist-demo
latest=$(ls -1dt runs/* | head -n1)
DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo CLICKHOUSE_URL=http://localhost:8123 BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby workloads/missing_index_todos/oracle.rb "$latest"
```

Expected:
- `git diff --check` clean
- finite run exits `0`
- oracle prints `PASS` lines

- [ ] **Step 5: Commit any journal-only verification note if needed**

Only if you learned something non-obvious during verification, append one concise bullet to `JOURNAL.md`, then commit it separately:

```bash
git add JOURNAL.md
git commit -m "docs: record constructor verification note"
```

If there is no new insight, do not create this commit.

## Self-Review

### Spec Coverage

- Group `Runner` constructor inputs into `Runtime`, `Config`, and `InvariantConfig`: covered in Task 1.
- Keep `verifier` in `Config`: covered in Task 1 `Config` construction and CLI wiring.
- Add `Runtime.default`: covered in Task 1.
- Move invariant sampler resolution/validation out of `initialize`: covered in Task 1 helper extraction.
- Preserve behavior and existing runner/CLI contracts: covered by Task 1 regression locks and Task 3 full verification.
- Avoid factory/generic options hash: preserved by the explicit constructor and no extra tasks for factories.

### Placeholder Scan

- No `TODO` / `TBD` placeholders remain.
- Every task includes exact file paths, code, commands, and expected outcomes.

### Type Consistency

- `Load::Runner::Runtime`, `Load::Runner::Config`, and `Load::Runner::InvariantConfig` are used consistently across tests and CLI wiring.
- `sample_interval_seconds` is used consistently inside `InvariantConfig` and monitor construction.
- `mode` and `verifier` live consistently on `Config`.

Plan complete and saved to `docs/superpowers/plans/2026-04-25-runner-constructor-plan.md`. Two execution options:

1. Subagent-Driven (recommended) - I dispatch a fresh subagent per task, review between tasks, fast iteration

2. Inline Execution - Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
