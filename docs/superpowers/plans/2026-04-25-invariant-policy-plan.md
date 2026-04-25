# Invariant Policy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `--invariants enforce|warn|off` to `bin/load run` and `bin/load soak` so operators can keep the current invariant-abort behavior, downgrade it to warnings, or disable invariant sampling entirely.

**Architecture:** Keep the invariant sampler itself unchanged and put policy in `Load::CLI` and `Load::Runner`. `Load::CLI` parses the new flag and passes an explicit `invariant_policy` into the runner; `Load::Runner` decides whether to start the invariant thread and whether breaches append warnings only or also trigger stop.

**Tech Stack:** Ruby, Minitest, OptionParser, existing `Load::Runner`/`Load::CLI`/`Load::RunRecord` code paths

---

## File Map

**Modify:**
- `load/lib/load/cli.rb` — parse `--invariants`, validate values, pass the policy into the runner factory, and update usage text.
- `load/lib/load/runner.rb` — store `invariant_policy`, skip invariant thread startup for `off`, and make breach handling policy-aware.
- `load/test/cli_test.rb` — cover default behavior, accepted values, and invalid values.
- `load/test/runner_test.rb` — cover `warn` behavior and `off` behavior without disturbing existing `enforce` tests.
- `README.md` — document the new flag in the `run` and `soak` sections.
- `JOURNAL.md` — record the decision and shipped contract.

**Verify Against:**
- `docs/superpowers/specs/2026-04-25-invariant-policy-design.md`

## Task 1: Add CLI Parsing For `--invariants`

**Files:**
- Modify: `load/test/cli_test.rb`
- Modify: `load/lib/load/cli.rb`

- [ ] **Step 1: Write the failing CLI tests**

Add four focused tests to `load/test/cli_test.rb`:

```ruby
def test_run_defaults_invariants_to_enforce
  recorded = nil
  runner_factory = lambda do |**kwargs|
    recorded = kwargs
    FakeRunner.new
  end

  cli = Load::CLI.new(
    argv: %W[run --workload missing-index-todos --adapter #{adapter_bin} --app-root #{app_root}],
    version: "test",
    runner_factory:,
    stdout: StringIO.new,
    stderr: StringIO.new,
  )

  assert_equal Load::ExitCodes::SUCCESS, cli.run
  assert_equal :enforce, recorded.fetch(:invariant_policy)
end

def test_run_accepts_warn_and_off_invariant_policies
  %i[warn off].each do |policy|
    recorded = nil
    runner_factory = lambda do |**kwargs|
      recorded = kwargs
      FakeRunner.new
    end

    cli = Load::CLI.new(
      argv: ["run", "--workload", "missing-index-todos", "--adapter", adapter_bin, "--app-root", app_root, "--invariants", policy.to_s],
      version: "test",
      runner_factory:,
      stdout: StringIO.new,
      stderr: StringIO.new,
    )

    assert_equal Load::ExitCodes::SUCCESS, cli.run
    assert_equal policy, recorded.fetch(:invariant_policy)
  end
end

def test_run_rejects_unknown_invariant_policy
  %w[run soak].each do |command|
    stderr = StringIO.new
    cli = Load::CLI.new(
      argv: [command, "--workload", "missing-index-todos", "--adapter", adapter_bin, "--app-root", app_root, "--invariants", "noisy"],
      version: "test",
      runner_factory: ->(**) { flunk "runner should not be built" },
      stdout: StringIO.new,
      stderr:,
    )

    assert_equal Load::ExitCodes::USAGE_ERROR, cli.run
    assert_includes stderr.string, "invalid --invariants"
  end
end

def test_verify_fixture_rejects_invariants_flag
  stderr = StringIO.new
  cli = Load::CLI.new(
    argv: %W[verify-fixture --workload missing-index-todos --adapter #{adapter_bin} --app-root #{app_root} --invariants warn],
    version: "test",
    verifier_factory: ->(**) { flunk "verifier should not be built" },
    stdout: StringIO.new,
    stderr:,
  )

  assert_equal Load::ExitCodes::USAGE_ERROR, cli.run
  assert_includes stderr.string, "invalid option"
end
```

- [ ] **Step 2: Run the CLI test file to confirm failure**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/cli_test.rb
```

Expected: FAIL because `Load::CLI` does not parse `--invariants` and does not pass `invariant_policy` into the runner factory.

- [ ] **Step 3: Implement minimal CLI parsing**

Update `load/lib/load/cli.rb`:

```ruby
USAGE = "Usage: bin/load run|soak|verify-fixture --workload NAME --adapter PATH --app-root PATH [--readiness-path /up|none] [--startup-grace-seconds 15] [--metrics-interval-seconds 5] [--invariants enforce|warn|off]".freeze

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
    parser.on("--invariants POLICY") do |value|
      options[:invariant_policy] = parse_invariant_policy(value)
    end
  end
  parser.parse!(@argv)
  # existing required-option checks stay here
  options
end

def parse_invariant_policy(value)
  policy = value.to_sym
  return policy if %i[enforce warn off].include?(policy)

  raise OptionParser::ParseError, "invalid --invariants: #{value}"
end
```

Plumb the parsed value through `run_command` and `default_runner_factory`:

```ruby
runner = @runner_factory.call(
  workload: workload,
  mode: mode,
  adapter_bin: options.fetch(:adapter_bin),
  app_root: options.fetch(:app_root),
  runs_dir: options.fetch(:runs_dir),
  readiness_path: options.fetch(:readiness_path),
  startup_grace_seconds: options.fetch(:startup_grace_seconds),
  metrics_interval_seconds: options.fetch(:metrics_interval_seconds),
  invariant_policy: options.fetch(:invariant_policy),
  stop_flag: @stop_flag,
  stdout: @stdout,
  stderr: @stderr,
)
```

- [ ] **Step 4: Run the CLI test file to verify it passes**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/cli_test.rb
```

Expected: PASS.

- [ ] **Step 5: Commit the CLI slice**

```bash
git add load/lib/load/cli.rb load/test/cli_test.rb
git commit -m "feat: add invariant policy cli flag"
```

## Task 2: Implement Runner `warn` Policy

**Files:**
- Modify: `load/test/runner_test.rb`
- Modify: `load/lib/load/runner.rb`

- [ ] **Step 1: Write the failing `warn`-mode runner tests**

Add two focused tests to `load/test/runner_test.rb`:

```ruby
def test_runner_enforce_policy_aborts_after_three_consecutive_breaches
  workers_ready = Queue.new
  BarrierAction.reset!
  BarrierAction.ready_queue = workers_ready
  sampler = FakeInvariantSampler.new(
    [
      Load::Runner::InvariantSample.new(open_count: 100, total_count: 10_000, open_floor: 30_000, total_floor: 80_000, total_ceiling: 200_000),
      Load::Runner::InvariantSample.new(open_count: 100, total_count: 10_000, open_floor: 30_000, total_floor: 80_000, total_ceiling: 200_000),
      Load::Runner::InvariantSample.new(open_count: 100, total_count: 10_000, open_floor: 30_000, total_floor: 80_000, total_ceiling: 200_000),
    ],
    first_sample_barrier: workers_ready,
  )
  run_record = FakeRunRecord.new
  runner = build_continuous_runner(run_record:, invariant_sampler: sampler, invariant_policy: :enforce)

  assert_equal Load::ExitCodes::ADAPTER_ERROR, Timeout.timeout(2.0) { runner.run }
  assert_equal "invariant_breach", run_record.read_run_json.dig("outcome", "error_code")
ensure
  BarrierAction.reset!
end

def test_runner_warn_policy_records_breaches_without_aborting
  stderr = StringIO.new
  stop_flag = Load::Runner::InternalStopFlag.new
  sampler = FakeInvariantSampler.new(
    [
      Load::Runner::InvariantSample.new(open_count: 100, total_count: 10_000, open_floor: 30_000, total_floor: 80_000, total_ceiling: 200_000),
      Load::Runner::InvariantSample.new(open_count: 100, total_count: 10_000, open_floor: 30_000, total_floor: 80_000, total_ceiling: 200_000),
      Load::Runner::InvariantSample.new(open_count: 100, total_count: 10_000, open_floor: 30_000, total_floor: 80_000, total_ceiling: 200_000),
    ],
  )
  run_record = FakeRunRecord.new
  runner = build_continuous_runner(
    run_record:,
    stop_flag:,
    invariant_sampler: sampler,
    invariant_policy: :warn,
    stderr:,
  )

  thread = Thread.new { runner.run }
  sampler.wait_until_drained
  stop_flag.trigger(:sigterm)

  assert_equal Load::ExitCodes::SUCCESS, Timeout.timeout(2.0) { thread.value }
  payload = run_record.read_run_json
  assert_equal 3, payload.fetch("warnings").length
  assert_equal 3, payload.fetch("invariant_samples").length
  assert_equal true, payload.dig("outcome", "aborted")
  assert_nil payload.dig("outcome", "error_code")
  assert_includes stderr.string, "warning: invariant breach:"
ensure
  thread&.kill
  thread&.join
end
```

If `build_continuous_runner` does not already accept `invariant_policy:` or `stderr:`, extend the test helper first and keep the helper changes inside this task.

- [ ] **Step 2: Run the targeted runner test to confirm failure**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb --name test_runner_warn_policy_records_breaches_without_aborting
```

Expected: FAIL because the runner currently treats three consecutive breaches as fatal regardless of operator intent, and it does not write breach lines to `stderr`.

- [ ] **Step 3: Implement minimal `warn` policy support**

First, widen the `Load::Runner` constructor so the final shape is explicit:

```ruby
def initialize(..., stop_flag: nil, verifier: nil, mode: :finite, invariant_policy: :enforce, invariant_sampler: nil, invariant_sample_interval_seconds: DEFAULT_INVARIANT_SAMPLE_INTERVAL_SECONDS, database_url: ENV["DATABASE_URL"], pg: PG, stderr: $stderr)
  @stderr = stderr
  @invariant_policy = invariant_policy
  @invariant_sampler = invariant_sampler || default_invariant_sampler(database_url:, pg:)
end
```

Add the maintainability comment directly above `sample_invariants`:

```ruby
# sample → breach? → enforce → ++counter → ≥3? → trigger_stop
#                  → warn    → @stderr.puts (no counter)
#                  → off     → unreachable (thread never started)
#       → !breach  → counter = 0 (enforce only; harmless elsewhere)
```

Then make `sample_invariants` policy-aware:

```ruby
def sample_invariants
  sample = @invariant_sampler.call
  append_invariant_sample(sample)
  unless sample.breach?
    @consecutive_invariant_breaches = 0 if @invariant_policy == :enforce
    return
  end

  append_warning(sample.to_warning)
  emit_invariant_warning(sample) if @invariant_policy == :warn

  return unless @invariant_policy == :enforce

  @consecutive_invariant_breaches += 1
  trigger_stop(:invariant_breach) if @consecutive_invariant_breaches >= 3
end

def emit_invariant_warning(sample)
  @stderr.puts("warning: invariant breach: #{sample.breaches.join('; ')}")
end
```

Thread `stderr` through the runner from `Load::CLI` the same way the runner factory already carries `stdout`/`stderr` context:

```ruby
Load::Runner.new(
  ...,
  invariant_policy:,
  stderr:,
)
```

Then write to the stored IO.

- [ ] **Step 4: Run the targeted runner test to verify it passes**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb --name test_runner_warn_policy_records_breaches_without_aborting
```

Expected: PASS.

- [ ] **Step 5: Run the existing invariant enforcement regression tests**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb --name '/test_runner_(aborts_after_three_consecutive_invariant_breaches|does_not_abort_when_breach_recovers|records_invariant_breach_before_first_successful_request)/'
```

Expected: PASS, proving `enforce` stays the default contract.

Run the new explicit-policy regression too:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb --name test_runner_enforce_policy_aborts_after_three_consecutive_breaches
```

Expected: PASS.

- [ ] **Step 6: Commit the `warn` policy slice**

```bash
git add load/lib/load/runner.rb load/test/runner_test.rb
git commit -m "feat: add invariant warning mode"
```

## Task 3: Implement Runner `off` Policy

**Files:**
- Modify: `load/test/runner_test.rb`
- Modify: `load/lib/load/runner.rb`

- [ ] **Step 1: Write the failing `off`-mode runner tests**

Add two focused tests to `load/test/runner_test.rb`:

```ruby
def test_runner_off_policy_skips_invariant_sampling
  stderr = StringIO.new
  sampler = RecordingInvariantSampler.new(clock: fake_clock_source)
  run_record = FakeRunRecord.new
  runner = Load::Runner.new(
    workload: MetricsWorkload.new,
    adapter_client: FakeAdapterClient.new,
    run_record:,
    clock: fake_clock,
    sleeper: ->(*) {},
    http: FakeHttp.new,
    readiness_path: nil,
    startup_grace_seconds: 0.0,
    mode: :continuous,
    invariant_policy: :off,
    invariant_sampler: sampler,
    stop_flag: Load::Runner::InternalStopFlag.new.tap { |flag| flag.trigger(:sigterm) },
    stderr:,
    database_url: nil,
  )

  assert_equal Load::ExitCodes::SUCCESS, runner.run
  assert_equal [], sampler.call_times
  payload = run_record.read_run_json
  assert_equal [], payload.fetch("warnings")
  assert_equal [], payload.fetch("invariant_samples")
  assert_equal "", stderr.string
end

def test_runner_off_policy_runs_without_database_url
  run_record = FakeRunRecord.new
  runner = Load::Runner.new(
    workload: MetricsWorkload.new,
    adapter_client: FakeAdapterClient.new,
    run_record:,
    clock: fake_clock,
    sleeper: ->(*) {},
    http: FakeHttp.new,
    readiness_path: nil,
    startup_grace_seconds: 0.0,
    mode: :continuous,
    invariant_policy: :off,
    stop_flag: Load::Runner::InternalStopFlag.new.tap { |flag| flag.trigger(:sigterm) },
    database_url: nil,
  )

  assert_equal Load::ExitCodes::SUCCESS, runner.run
end
```

Use the existing test clock helpers already present in `load/test/runner_test.rb`; do not invent a new fake clock abstraction if one is already in the file.

- [ ] **Step 2: Run the targeted runner test to confirm failure**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb --name test_runner_off_policy_skips_invariant_sampling
```

Expected: FAIL because the runner currently always builds and starts the invariant thread in continuous mode.

- [ ] **Step 3: Implement minimal `off` policy support**

Gate thread startup in `load/lib/load/runner.rb`:

```ruby
def start_invariant_thread
  return unless @mode == :continuous
  return if @invariant_policy == :off
  return unless @invariant_sampler

  Thread.new do
    # existing thread body
  end
end
```

Keep `default_invariant_sampler` lazy enough that `off` mode does not raise the existing `continuous mode requires DATABASE_URL` error just because the policy disabled sampling. The constructor path should look like:

```ruby
@invariant_sampler =
  if @invariant_policy == :off
    nil
  else
    invariant_sampler || default_invariant_sampler(database_url:, pg:)
  end
```

Update the guard message in `default_invariant_sampler`:

```ruby
raise AdapterClient::AdapterError, "continuous mode requires DATABASE_URL, an explicit invariant sampler, or --invariants off"
```

- [ ] **Step 4: Run the targeted runner test to verify it passes**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb --name test_runner_off_policy_skips_invariant_sampling
```

Expected: PASS.

- [ ] **Step 5: Run the targeted CLI and runner files together**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby -e 'load "load/test/cli_test.rb"; load "load/test/runner_test.rb"'
```

Expected: PASS.

- [ ] **Step 6: Commit the `off` policy slice**

```bash
git add load/lib/load/runner.rb load/test/runner_test.rb
git commit -m "feat: allow disabling invariant sampling"
```

## Task 4: Document The New Flag

**Files:**
- Modify: `README.md`
- Modify: `JOURNAL.md`

- [ ] **Step 1: Write the documentation changes**

First, confirm the current section headers in `README.md` still match the run-mode structure introduced in commit `0994115`:

```bash
rg -n '^#### `bin/load (run|soak|verify-fixture)`' README.md
```

Expected:

```text
#### `bin/load run`
#### `bin/load soak`
#### `bin/load verify-fixture`
```

Then update `README.md` in the existing `run` and `soak` sections:

```md
- `--invariants enforce|warn|off` controls how the runner reacts to invariant breaches
- `enforce` is the default and aborts after three consecutive breached samples
- `warn` keeps sampling and records warnings without stopping the run
- `off` disables invariant sampling entirely for that run
```

Add one concrete command example:

```bash
bin/load soak --workload missing-index-todos \
  --adapter adapters/rails/bin/bench-adapter \
  --app-root /home/bjw/db-specialist-demo \
  --invariants warn
```

Add one explicit note under `verify-fixture`:

```md
`verify-fixture` does not use the invariant sampler, so `--invariants` does not apply to that command.
```

Update `JOURNAL.md` with one short entry recording:

```md
- Added `--invariants enforce|warn|off` so operators can keep, downgrade, or disable invariant enforcement per run without changing workload code.
```

- [ ] **Step 2: Run a doc hygiene check**

Run:

```bash
git diff --check -- README.md JOURNAL.md
```

Expected: no output.

- [ ] **Step 3: Commit the docs slice**

```bash
git add README.md JOURNAL.md
git commit -m "docs: describe invariant policy modes"
```

## Task 5: Full Verification

**Files:**
- Verify only

- [ ] **Step 1: Run the focused load suite**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby -e 'Dir["load/test/*_test.rb"].sort.each { |path| load path }'
```

Expected: PASS with no new skips.

- [ ] **Step 2: Run the repo test target**

Run:

```bash
make test
```

Expected:

```text
load: PASS
adapters: PASS
workloads: PASS
```

The adapters suite should still show only the existing two opt-in skips.

- [ ] **Step 3: Spot-check CLI behavior manually**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby bin/load --help
```

Expected: usage text includes `--invariants enforce|warn|off`.

- [ ] **Step 4: Run live operator smokes for `warn` and `off`**

Run:

```bash
DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo \
BENCH_ADAPTER_PG_ADMIN_URL=postgres://postgres:postgres@localhost:5432/postgres \
BUNDLE_GEMFILE=collector/Gemfile \
bundle exec bin/load soak --workload missing-index-todos --invariants warn \
  --adapter adapters/rails/bin/bench-adapter \
  --app-root /home/bjw/db-specialist-demo
```

Degrade the fixture after startup, then confirm:

- one or more `warning: invariant breach:` lines on `stderr`
- `run.json.warnings` contains invariant-breach entries
- `run.json.invariant_samples` contains breached samples
- the soak exits cleanly on `SIGTERM` without `outcome.error_code: "invariant_breach"`

Run:

```bash
DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo \
BENCH_ADAPTER_PG_ADMIN_URL=postgres://postgres:postgres@localhost:5432/postgres \
BUNDLE_GEMFILE=collector/Gemfile \
bundle exec bin/load soak --workload missing-index-todos --invariants off \
  --adapter adapters/rails/bin/bench-adapter \
  --app-root /home/bjw/db-specialist-demo
```

Confirm:

- fixture verification still runs before workers start
- `run.json.warnings` stays empty
- `run.json.invariant_samples` stays empty
- `stderr` contains no invariant-breach warning lines

- [ ] **Step 5: Commit any verification-only fallout if needed**

If verification exposes a small missing test or doc detail, fix it with TDD first, rerun the affected commands, then commit:

```bash
git add <exact files>
git commit -m "test: close invariant policy verification gap"
```

If there is no fallout, do not create an extra commit.

---

## Self-Review

### Spec Coverage

- CLI contract: covered in Task 1.
- `enforce|warn|off` behavior: covered in Tasks 2 and 3.
- regression lock: `:enforce` policy still aborts after 3 breaches: covered in Task 2.
- `:off` policy disables invariant sampling but does not bypass fixture verification: covered in Tasks 3 and 5.
- `stderr` output for `warn`: covered in Task 2.
- docs and `verify-fixture` note: covered in Task 4.
- regression proof that `enforce` stayed default: covered in Tasks 2 and 5.

### Placeholder Scan

No `TODO`, `TBD`, or “handle appropriately” placeholders remain. Each task has explicit files, code, commands, and expected outcomes.

### Type Consistency

- Policy value is consistently named `invariant_policy`.
- Policy values are consistently `:enforce`, `:warn`, `:off`.
- CLI flag is consistently `--invariants`.
