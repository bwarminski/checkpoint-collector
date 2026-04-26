# PlanetScale Reset/Soak Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable `bin/load soak` to reset/reseed and run against an existing PlanetScale Postgres branch while preserving local Docker behavior.

**Architecture:** Keep the existing load runner and Rails adapter contract. Add an explicit Rails adapter reset strategy for remote Postgres, and add collector stats-only mode so PlanetScale runs can poll `pg_stat_statements` without local Postgres log files. Validate with unit tests first, then run focused checkpoints against a real PlanetScale branch before widening the change.

**Tech Stack:** Ruby, Minitest, Rails adapter subprocess commands, PostgreSQL `pg_stat_statements`, ClickHouse, Docker Compose for local verification.

---

## File Map

- Modify `adapters/rails/lib/rails_adapter/commands/reset_state.rb`: select local vs remote reset strategy and implement remote reset flow.
- Modify `adapters/rails/test/reset_state_test.rb`: TDD coverage for strategy selection, remote command order, and failure phases.
- Modify `collector/bin/collector`: add runtime flag that skips log ingestion while preserving stats polling.
- Modify `collector/test/runtime_orchestration_test.rb`: TDD coverage for stats-only runtime.
- Modify `README.md`: document PlanetScale operator flow, env vars, destructive reset warning, and deferred logs/branch work.
- Modify `Makefile`: add a convenience `load-soak-planetscale` target that requires caller-provided env vars and does not embed credentials.
- Modify `JOURNAL.md`: record integration findings during real PlanetScale checkpoints.

## Checkpoint Policy

Run real PlanetScale validation after Task 2, before collector/docs work:

- First live checkpoint proves remote reset/reseed can load schema, seed data, create/reset `pg_stat_statements`, and capture query IDs.
- Second live checkpoint proves stats-only collector can poll PlanetScale and write ClickHouse intervals.
- Final live checkpoint runs a short PlanetScale soak and inspects `run.json`, `metrics.jsonl`, and ClickHouse query evidence.

If a live checkpoint fails, stop and debug the integration issue before continuing to later tasks.

### Task 1: Add Remote Reset Strategy Tests

**Files:**
- Modify: `adapters/rails/test/reset_state_test.rb`

- [ ] **Step 1: Write failing test for explicit remote strategy**

Add this test to `ResetStateTest` after `test_reset_state_uses_template_clone_after_first_build`:

```ruby
def test_reset_state_remote_strategy_skips_template_cache_and_runs_schema_seed_and_stats_steps
  query_ids_json = %({"query_ids":["111"]})
  runner = FakeCommandRunner.new(
    results: {
      ["bin/rails", "runner", RailsAdapter::Commands::ResetState::QUERY_IDS_SCRIPT.fetch("missing-index-todos")] => FakeResult.new(status: 0, stdout: query_ids_json, stderr: ""),
    },
  )
  cache = FakeTemplateCache.new
  command = RailsAdapter::Commands::ResetState.new(
    app_root: "/tmp/demo",
    workload: "missing-index-todos",
    seed: 42,
    env_pairs: { "ROWS_PER_TABLE" => "100000", "OPEN_FRACTION" => "0.6", "USER_COUNT" => "100" },
    command_runner: runner,
    template_cache: cache,
    reset_strategy: "remote",
    clock: fake_clock(0.0, 1.0),
  )

  result = command.call

  assert result.fetch("ok"), result.inspect
  assert_equal ["111"], result.fetch("query_ids")
  assert_equal 0, cache.build_calls
  assert_equal 0, cache.clone_calls
  assert_equal [
    ["bin/rails", "db:schema:load"],
    ["bin/rails", "runner", %(load Rails.root.join("db/seeds.rb").to_s)],
    ["bin/rails", "runner", %(ActiveRecord::Base.connection.execute("CREATE EXTENSION IF NOT EXISTS pg_stat_statements"))],
    ["bin/rails", "runner", RailsAdapter::Commands::ResetState::QUERY_IDS_SCRIPT.fetch("missing-index-todos")],
    ["bin/rails", "runner", %(ActiveRecord::Base.connection.execute("SELECT pg_stat_statements_reset()"))],
  ], runner.argv_history
end
```

- [ ] **Step 2: Write failing test for remote schema failure phase**

Add this test after the remote success test:

```ruby
def test_reset_state_remote_strategy_reports_schema_load_failure
  runner = FakeCommandRunner.new(
    results: {
      ["bin/rails", "db:schema:load"] => FakeResult.new(status: 1, stdout: "", stderr: "schema failed"),
    },
  )
  command = RailsAdapter::Commands::ResetState.new(
    app_root: "/tmp/demo",
    workload: "missing-index-todos",
    seed: 42,
    env_pairs: {},
    command_runner: runner,
    template_cache: FakeTemplateCache.new,
    reset_strategy: "remote",
    clock: fake_clock(0.0, 1.0),
  )

  result = command.call

  refute result.fetch("ok")
  assert_equal "reset_failed", result.fetch("error_code")
  assert_includes result.fetch("message"), "schema load failed"
end
```

- [ ] **Step 3: Run tests and verify failure**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby adapters/rails/test/reset_state_test.rb
```

Expected: fails with `unknown keyword: :reset_strategy` or equivalent missing remote-strategy behavior.

### Task 2: Implement Remote Reset Strategy

**Files:**
- Modify: `adapters/rails/lib/rails_adapter/commands/reset_state.rb`
- Test: `adapters/rails/test/reset_state_test.rb`

- [ ] **Step 1: Add constructor argument and strategy dispatch**

Change the initializer signature and `call` body in `ResetState` to:

```ruby
def initialize(app_root:, seed:, env_pairs:, workload: nil, command_runner: RailsAdapter::CommandRunner.new, template_cache: RailsAdapter::TemplateCache.new, reset_strategy: ENV.fetch("BENCH_ADAPTER_RESET_STRATEGY", "local"), clock: -> { Time.now.to_f })
  @app_root = app_root
  @workload = workload
  @seed = seed
  @env_pairs = env_pairs
  @command_runner = command_runner
  @template_cache = template_cache
  @reset_strategy = reset_strategy
  @clock = clock
end

def call
  case @reset_strategy
  when "local"
    reset_local
  when "remote"
    reset_remote
  else
    raise ArgumentError, "unknown reset strategy: #{@reset_strategy}"
  end

  ensure_pg_stat_statements
  query_ids = capture_query_ids
  reset_pg_stat_statements
  RailsAdapter::Result.ok("reset-state", query_ids ? { "query_ids" => query_ids } : {})
rescue StandardError => error
  RailsAdapter::Result.error("reset-state", "reset_failed", error.message, {})
end
```

- [ ] **Step 2: Extract local reset and add remote reset**

Replace the template-cache block in `call` with these private methods:

```ruby
def reset_local
  if @template_cache.template_exists?(database_name: database_name, app_root: @app_root, env_pairs: seed_env)
    @template_cache.clone_template(database_name: database_name, app_root: @app_root, env_pairs: seed_env)
  else
    build_template
    @template_cache.build_template(database_name: database_name, app_root: @app_root, env_pairs: seed_env)
  end
end

def reset_remote
  schema = @command_runner.capture3(
    "bin/rails",
    "db:schema:load",
    env: rails_env,
    chdir: @app_root,
    command_name: "reset-state",
  )
  raise "schema load failed" unless schema.success?

  load_dataset = RailsAdapter::Commands::LoadDataset.new(
    app_root: @app_root,
    workload: @workload,
    seed: @seed,
    env_pairs: @env_pairs,
    command_runner: @command_runner,
    clock: @clock,
  ).call
  raise "seed failed" unless load_dataset.fetch("ok")
end
```

Keep `build_template`, `ensure_pg_stat_statements`, `capture_query_ids`, and `reset_pg_stat_statements` as existing helpers.

- [ ] **Step 3: Run reset-state tests**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby adapters/rails/test/reset_state_test.rb
```

Expected: all tests pass.

- [ ] **Step 4: Run adapter test suite**

Run:

```bash
make test-adapters
```

Expected: all adapter tests pass, with existing skips unchanged.

- [ ] **Step 5: Commit adapter reset work**

Run:

```bash
git status --short
git add adapters/rails/lib/rails_adapter/commands/reset_state.rb adapters/rails/test/reset_state_test.rb
git commit -m "feat: add remote reset strategy"
```

### Task 3: Live PlanetScale Reset Checkpoint

**Files:**
- Modify: `JOURNAL.md`

- [ ] **Step 1: Confirm required env is present without printing secrets**

Run:

```bash
ruby -e 'required=%w[DATABASE_URL BENCH_ADAPTER_PG_ADMIN_URL]; missing=required.reject { |key| ENV[key].to_s != "" }; abort("missing #{missing.join(", ")}") unless missing.empty?; puts "PlanetScale reset env present: #{required.join(", ")}"'
```

Expected: prints `PlanetScale reset env present: DATABASE_URL, BENCH_ADAPTER_PG_ADMIN_URL`.

- [ ] **Step 2: Run remote adapter reset against PlanetScale**

Run:

```bash
BENCH_ADAPTER_RESET_STRATEGY=remote \
adapters/rails/bin/bench-adapter --json reset-state \
  --app-root /home/bjw/db-specialist-demo \
  --workload missing-index-todos \
  --seed 42 \
  --env ROWS_PER_TABLE=100000 \
  --env OPEN_FRACTION=0.6 \
  --env USER_COUNT=100
```

Expected: JSON with `"ok":true` and a non-empty `"query_ids"` array.

- [ ] **Step 3: Verify remote counts through direct admin URL**

Run:

```bash
ruby -rpg -e 'conn=PG.connect(ENV.fetch("BENCH_ADAPTER_PG_ADMIN_URL")); puts conn.exec("select count(*) as total_count, count(*) filter (where status = '\''open'\'') as open_count from todos").first; conn.close'
```

Expected: `total_count` is near `100000` and `open_count` is near `60000`.

- [ ] **Step 4: Verify stats reset happened**

Run:

```bash
ruby -rpg -e 'conn=PG.connect(ENV.fetch("BENCH_ADAPTER_PG_ADMIN_URL")); puts conn.exec("select stats_reset from pg_stat_statements_info").first.fetch("stats_reset"); conn.close'
```

Expected: prints a recent timestamp. The adapter reset JSON from Step 2 is the source of truth for captured query IDs because reset clears statement stats after capture.

- [ ] **Step 5: Record checkpoint findings**

Append a journal entry with the actual query ID count and any observed integration behavior. Example format:

```markdown
- 2026-04-26 PlanetScale reset checkpoint: remote reset-state against existing branch succeeded with `ROWS_PER_TABLE=100000`, `OPEN_FRACTION=0.6`, `USER_COUNT=100`; query ID capture returned 1 id, and `pg_stat_statements_info.stats_reset` updated after capture. Integration note: no additional PlanetScale-specific reset behavior observed.
```

Use `apply_patch`, then commit:

```bash
git add JOURNAL.md
git commit -m "docs: record planetscale reset checkpoint"
```

If any checkpoint step fails, stop and debug that specific failure before Task 4.

### Task 4: Add Collector Stats-Only Tests

**Files:**
- Modify: `collector/test/runtime_orchestration_test.rb`

- [ ] **Step 1: Write failing stats-only test**

Add this test before `private`:

```ruby
def test_run_once_pass_can_skip_log_ingestion_while_collecting_stats
  events = []
  clickhouse_service = FakeClickhouseService.new(events: events)
  observed_offsets = []
  stats_connections = []
  clickhouse_connections = []

  runtime = build_runtime(
    events: events,
    clickhouse_service: clickhouse_service,
    observed_offsets: observed_offsets,
    stats_connections: stats_connections,
    clickhouse_connections: clickhouse_connections,
    log_reader: lambda do |_, byte_offset|
      observed_offsets << byte_offset
      raise "log reader should not be called"
    end,
    log_ingestion_enabled: false,
  )

  runtime.run_once_pass

  assert_equal [], observed_offsets
  assert_equal [
    [:stats_exec, 1, Collector::STATS_SQL],
    [:stats_exec, 1, Collector::INFO_SQL],
    [:insert, 1, "query_events"],
    [:stats_close, 1],
  ], events
end
```

- [ ] **Step 2: Update test helper signature to pass the new flag**

Change `build_runtime` signature in the test file to:

```ruby
def build_runtime(events:, clickhouse_service:, observed_offsets:, stats_connections:, clickhouse_connections:, log_reader:, clickhouse_url: "http://clickhouse:8123", log_ingestion_enabled: true)
```

Pass the flag into `CollectorRuntime.new`:

```ruby
log_ingestion_enabled: log_ingestion_enabled,
```

- [ ] **Step 3: Run test and verify failure**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby collector/test/runtime_orchestration_test.rb
```

Expected: fails with `unknown keyword: :log_ingestion_enabled`.

### Task 5: Implement Collector Stats-Only Mode

**Files:**
- Modify: `collector/bin/collector`
- Test: `collector/test/runtime_orchestration_test.rb`

- [ ] **Step 1: Add runtime constructor flag**

In `CollectorRuntime#initialize`, add keyword:

```ruby
log_ingestion_enabled: ENV.fetch("COLLECTOR_DISABLE_LOG_INGESTION", nil).nil?,
```

Store it:

```ruby
@log_ingestion_enabled = log_ingestion_enabled
```

- [ ] **Step 2: Guard log ingestion in `run_once_pass`**

Replace the unconditional log ingester construction and `ingest_file(@log_file)` call with:

```ruby
if @log_ingestion_enabled
  @log_ingester_class.new(
    log_reader: @log_reader,
    clickhouse_connection: clickhouse_connection,
    state_store: state_store,
    clock: @clock,
    stderr: @stderr
  ).ingest_file(@log_file)
end
```

- [ ] **Step 3: Pass env-derived flag in executable block**

Update the bottom executable `CollectorRuntime.new` call:

```ruby
CollectorRuntime.new(
  interval_seconds: Integer(ENV.fetch("COLLECTOR_INTERVAL_SECONDS", "5")),
  postgres_url: ENV.fetch("POSTGRES_URL"),
  clickhouse_url: ENV.fetch("CLICKHOUSE_URL"),
  log_file: ENV.fetch("POSTGRES_LOG_PATH", CollectorRuntime::DEFAULT_LOG_FILE),
  log_ingestion_enabled: ENV.fetch("COLLECTOR_DISABLE_LOG_INGESTION", nil).nil?
).run_forever
```

- [ ] **Step 4: Run collector runtime tests**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby collector/test/runtime_orchestration_test.rb
```

Expected: all tests pass.

- [ ] **Step 5: Run collector tests**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby -e 'Dir["collector/test/*_test.rb"].sort.each { |path| load path }'
```

Expected: all collector tests pass.

- [ ] **Step 6: Commit collector stats-only work**

Run:

```bash
git status --short
git add collector/bin/collector collector/test/runtime_orchestration_test.rb
git commit -m "feat: add collector stats-only mode"
```

### Task 6: Live PlanetScale Collector Checkpoint

**Files:**
- Modify: `JOURNAL.md`

- [ ] **Step 1: Start local ClickHouse only**

Run:

```bash
docker compose up -d clickhouse
```

Expected: ClickHouse service is healthy.

- [ ] **Step 2: Run one stats-only collector pass against PlanetScale**

Run:

```bash
COLLECTOR_DISABLE_LOG_INGESTION=1 \
POSTGRES_URL="$BENCH_ADAPTER_PG_ADMIN_URL" \
CLICKHOUSE_URL=http://localhost:8123 \
BUNDLE_GEMFILE=collector/Gemfile \
bundle exec ruby -r./collector/bin/collector -e 'CollectorRuntime.new(interval_seconds: 5, postgres_url: ENV.fetch("POSTGRES_URL"), clickhouse_url: ENV.fetch("CLICKHOUSE_URL"), log_ingestion_enabled: false).run_once_pass'
```

Expected: exits `0`.

- [ ] **Step 3: Verify ClickHouse received query events**

Run:

```bash
docker compose exec clickhouse clickhouse-client --query "SELECT count() FROM query_events"
```

Expected: count is greater than `0`.

- [ ] **Step 4: Record checkpoint findings**

Append a journal entry with the actual row count. Example format:

```markdown
- 2026-04-26 PlanetScale collector checkpoint: stats-only collector pass against PlanetScale wrote 12 rows to local ClickHouse without reading Postgres logs. Integration note: no additional collector permissions issue observed.
```

Use `apply_patch`, then commit:

```bash
git add JOURNAL.md
git commit -m "docs: record planetscale collector checkpoint"
```

If this checkpoint fails, stop and debug collector connectivity or PlanetScale `pg_stat_statements` permissions before Task 7.

### Task 7: Add Operator Docs and Make Target

**Files:**
- Modify: `README.md`
- Modify: `Makefile`

- [ ] **Step 1: Add Make target**

Add `load-soak-planetscale` to `.PHONY` and append:

```make
load-soak-planetscale:
	@test -n "$$DATABASE_URL" || (echo "DATABASE_URL is required" >&2; exit 1)
	@test -n "$$BENCH_ADAPTER_PG_ADMIN_URL" || (echo "BENCH_ADAPTER_PG_ADMIN_URL is required" >&2; exit 1)
	BENCH_ADAPTER_RESET_STRATEGY=remote bin/load soak --workload missing-index-todos --adapter adapters/rails/bin/bench-adapter --app-root /home/bjw/db-specialist-demo
```

- [ ] **Step 2: Add README section**

Add a `## PlanetScale Soak` section after the Run Modes overview. Include:

````markdown
## PlanetScale Soak

PlanetScale soak targets an existing benchmark branch and resets that branch before workers start. This is destructive to the target database; do not point these commands at production.

Before running it, enable `pg_stat_statements` for the PlanetScale branch in the dashboard, apply the extension change, and run `CREATE EXTENSION IF NOT EXISTS pg_stat_statements;` in the benchmark database.

Use PgBouncer for app traffic and a direct connection for setup/stat polling:

```bash
export DATABASE_URL='postgresql://USER:PASSWORD@HOST:6432/DATABASE?sslmode=require'
export BENCH_ADAPTER_PG_ADMIN_URL='postgresql://USER:PASSWORD@HOST:5432/DATABASE?sslmode=require'
export POSTGRES_URL="$BENCH_ADAPTER_PG_ADMIN_URL"
```

Run a reset/reseed checkpoint:

```bash
BENCH_ADAPTER_RESET_STRATEGY=remote \
adapters/rails/bin/bench-adapter --json reset-state \
  --app-root /home/bjw/db-specialist-demo \
  --workload missing-index-todos \
  --seed 42 \
  --env ROWS_PER_TABLE=100000 \
  --env OPEN_FRACTION=0.6 \
  --env USER_COUNT=100
```

Run soak:

```bash
BENCH_ADAPTER_RESET_STRATEGY=remote \
bin/load soak --workload missing-index-todos \
  --adapter adapters/rails/bin/bench-adapter \
  --app-root /home/bjw/db-specialist-demo
```

Run the collector against PlanetScale in stats-only mode:

```bash
COLLECTOR_DISABLE_LOG_INGESTION=1 \
POSTGRES_URL="$POSTGRES_URL" \
CLICKHOUSE_URL=http://localhost:8123 \
BUNDLE_GEMFILE=collector/Gemfile \
bundle exec ruby collector/bin/collector
```

Branch-per-run automation and PlanetScale Logs/Insights ingestion are future work. The first PlanetScale path uses `pg_stat_statements` as query evidence.
````

- [ ] **Step 3: Run docs/target smoke checks**

Run:

```bash
make -n load-soak-planetscale
```

Expected: prints the env validation and `bin/load soak` command without executing soak.

- [ ] **Step 4: Commit docs and Makefile**

Run:

```bash
git status --short
git add README.md Makefile
git commit -m "docs: add planetscale soak operator path"
```

### Task 8: Full Local Verification

**Files:**
- No edits expected.

- [ ] **Step 1: Run load tests**

Run:

```bash
make test-load
```

Expected: pass.

- [ ] **Step 2: Run adapter tests**

Run:

```bash
make test-adapters
```

Expected: pass with existing skips unchanged.

- [ ] **Step 3: Run workload tests**

Run:

```bash
make test-workloads
```

Expected: pass.

- [ ] **Step 4: Run collector tests**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby -e 'Dir["collector/test/*_test.rb"].sort.each { |path| load path }'
```

Expected: pass.

- [ ] **Step 5: Record verification**

Append a journal entry with the exact commands and results, then commit:

```bash
git add JOURNAL.md
git commit -m "docs: record planetscale local verification"
```

### Task 9: Final Live PlanetScale Soak Checkpoint

**Files:**
- Modify: `JOURNAL.md`

- [ ] **Step 1: Ensure local ClickHouse is running**

Run:

```bash
docker compose up -d clickhouse
```

Expected: ClickHouse is healthy.

- [ ] **Step 2: Start stats-only collector**

Run in a managed terminal session:

```bash
COLLECTOR_DISABLE_LOG_INGESTION=1 \
POSTGRES_URL="$BENCH_ADAPTER_PG_ADMIN_URL" \
CLICKHOUSE_URL=http://localhost:8123 \
BUNDLE_GEMFILE=collector/Gemfile \
bundle exec ruby collector/bin/collector
```

Expected: collector keeps running without log-file errors.

- [ ] **Step 3: Run PlanetScale soak with remote reset**

Run:

```bash
BENCH_ADAPTER_RESET_STRATEGY=remote \
bin/load soak --workload missing-index-todos --invariants warn \
  --adapter adapters/rails/bin/bench-adapter \
  --app-root /home/bjw/db-specialist-demo
```

Let it run until at least one metrics interval and one collector poll have completed, then stop with `Ctrl-C`.

Expected: run directory is created, `run.json.window.start_ts` is set, `metrics.jsonl` has action metrics, and `run.json.query_ids` is non-empty.

- [ ] **Step 4: Inspect run artifacts**

Run:

```bash
latest=$(ls -1dt runs/* | head -n1)
sed -n '1,220p' "$latest/run.json"
tail -n 20 "$latest/metrics.jsonl"
```

Expected: successful requests are present and no immediate adapter/readiness error is recorded.

- [ ] **Step 5: Inspect ClickHouse evidence**

Run:

```bash
docker compose exec clickhouse clickhouse-client --query "
  SELECT toString(queryid), sum(total_exec_count)
  FROM query_intervals
  GROUP BY queryid
  ORDER BY sum(total_exec_count) DESC
  LIMIT 10
"
```

Expected: PlanetScale query IDs appear in interval evidence.

- [ ] **Step 6: Stop collector and record findings**

Stop the collector session cleanly. Append a journal entry with:

- run directory
- reset result
- collector evidence count
- any PlanetScale-specific integration issue

Commit:

```bash
git add JOURNAL.md
git commit -m "docs: record planetscale soak checkpoint"
```

If the final checkpoint exposes integration defects, fix them with TDD in a new small task before claiming PlanetScale soak works.
