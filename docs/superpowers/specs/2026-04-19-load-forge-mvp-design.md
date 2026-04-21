# Load Runner MVP — Design Spec

**Status:** Spec, ready for implementation
**Date:** 2026-04-19
**Supersedes:** `docs/superpowers/plans/2026-04-18-fixture-harness-plan.md` (the existing `bin/fixture missing-index` harness is deleted as part of this work). Also absorbs and replaces the toy `/load/harness.rb`.

## 1. Overview

A generic HTTP load runner (`bin/load`) for benchmarking database-backed webapps and eventually feeding their performance signals into a closed-loop optimizer (an LLM). This MVP ships:

- A Ruby runner under `/load/` that drives a declared workload against an app-under-test's normal HTTP surface.
- A CLI adapter contract that mediates app lifecycle (prepare/migrate/seed/reset/start/stop) using framework-native mechanisms.
- One concrete adapter for Rails.
- One workload (`missing-index-todos`) that reaches parity with today's `bin/fixture missing-index` behavior.
- Structured per-run output suitable for human inspection today and LLM consumption later.

The app-under-test (`~/db-specialist-demo`, external to this repo) stays a normal Rails app. Its only benchmark-adjacent change: `db/seeds.rb` is parameterized by env vars so the adapter can drive seeding via `bin/rails runner`. No `/__bench` routes, no admin controllers, no benchmark middleware.

Database observability is NOT part of the runner or the adapter. The existing checkpoint-collector already scrapes `pg_stat_statements` into ClickHouse. The runner pins a time window; oracle scripts (and eventually LLM tooling) query ClickHouse for that window.

## 2. Goals & Non-Goals

### Goals

1. Generic HTTP load runner that takes a workload as Ruby code and drives normal app endpoints with weighted action mix and pacing.
2. Framework-neutral CLI adapter contract with one working Rails implementation.
3. Run output that captures enough per-run state (metadata + interval-aggregated metrics) to interpret after the fact.
4. Parity with today's `bin/fixture missing-index` pathology reproduction: seq-scan-driving workload against a 10M-row `todos` table, with a tactical oracle script that reports PASS/FAIL.
5. No benchmark-only code in the app-under-test beyond a parameterized `db/seeds.rb`.

### Non-Goals

1. Multiple adapters (Express, Dropwizard). Rails only.
2. Signal library, declarative signal specs, or shared assertion DSL. Oracle scripts are tactical, workload-local, deprecatable.
3. LLM patch application, run-compare tooling, optimization loop automation.
4. Multiple reset modes. One reset behavior: full.
5. Adapter versioning, capability discovery, state-dir protocol. Keep the contract narrow.
6. Readiness probing as a contract primitive. Runner waits a grace period; workers that hit a not-yet-ready app record errors honestly.
7. Per-request on-disk trace. Workers aggregate in memory and report at intervals.
8. Distributed runners, remote adapters, multi-host load generation.

## 3. Architecture

```
+----------------------------+          +------------------------------+
|  Runner (bin/load)         |          |  App-Under-Test (external)   |
|----------------------------|          |------------------------------|
|  Workload loader           |          |  ~/db-specialist-demo        |
|  AdapterClient             |          |  Normal Rails app            |
|  Worker pool + selector    |  HTTP    |  db/seeds.rb reads ENV       |
|  Rate limiter              |------->  |  Standard routes (/todos/..) |
|  Metrics reporter          |          |                              |
|  Run-record writer         |          |                              |
+----------+-----------------+          +--------------+---------------+
           |                                           |
           | CLI (JSON)                                |
           v                                           v
+----------------------------+          +------------------------------+
|  Rails Adapter             |          |  Postgres                    |
|  (adapters/rails/bin/...)  |          |  (existing in docker compose)|
|----------------------------|          |------------------------------|
|  Wraps bin/rails           |          |  pg_stat_statements          |
+----------------------------+          +------------------------------+
                                                       |
                                                       | scraped
                                                       v
                                          +------------------------------+
                                          |  Collector + ClickHouse      |
                                          |  (existing, unchanged)       |
                                          +------------------------------+
```

The runner never talks to Postgres. The adapter talks to the app-under-test's Postgres only through Rails for ordinary data paths (migrate, seed). One intentional exception: when template caching is enabled (§6.5), the adapter connects to Postgres as a privileged role to run `CREATE DATABASE ... TEMPLATE ...` / `DROP DATABASE`. That is the only time the adapter reaches Postgres outside the Rails subprocess, and it's explicitly an adapter-private capability, not part of the adapter contract. Observability is the collector's job.

## 4. Repo Layout

```
/load                            # the runner
  /lib/load
    workload.rb                  # base class
    action.rb                    # base class
    action_entry.rb              # Data.define(:action_class, :weight)
    scale.rb                     # Data.define(:seed, ...workload-specific fields)
    load_plan.rb                 # Data.define(:workers, :duration_seconds, :rate_limit, :seed)
    client.rb                    # thin HTTP client wrapper per worker
    rate_limiter.rb              # ported from today's drive.rb
    selector.rb                  # weighted action selection
    worker.rb                    # one thread per worker
    metrics.rb                   # in-memory aggregation + periodic snapshot
    reporter.rb                  # background thread that snapshots workers to metrics.jsonl
    adapter_client.rb            # Open3 wrapper around the adapter CLI
    run_record.rb                # writes run.json, metrics.jsonl, adapter-commands.jsonl
    runner.rb                    # top-level orchestration
  /test

/workloads
  /missing_index_todos
    workload.rb                  # Load::Workloads::MissingIndexTodos
    actions/
      list_open_todos.rb
    oracle.rb                    # tactical EXPLAIN + ClickHouse verifier
    README.md

/adapters
  /rails
    bin/bench-adapter
    lib/
      rails_adapter.rb
      commands/
        prepare.rb
        migrate.rb
        load_dataset.rb
        reset_state.rb
        start.rb
        stop.rb
        describe.rb
    test/
    README.md

/bin/load                        # top-level binary
```

Deletions in this same change:

```
/bin/fixture
/fixtures/missing-index/          (entire directory)
/collector/lib/fixtures/          (command.rb, manifest.rb)
/collector/test/fixtures/         (all tests)
/load/harness.rb                  (replaced by /load/lib/load/...)
/load/README.md                   (rewritten)
/fixture-harness-walkthrough.md
```

Existing `/collector` Ruby library, docker-compose stack, Postgres and ClickHouse schemas stay untouched.

## 5. Adapter Contract

### 5.1 CLI shape

Every command:

- is invoked as `bench-adapter <command> [flags]`
- accepts `--app-root <path>` where relevant
- accepts `--json` globally and emits a single JSON object to stdout on success or failure
- exits 0 on success, non-zero on failure
- may write human-readable logs to stderr

**Success:** `{"ok": true, "command": "<name>", ...command-specific fields}`.
**Error:** `{"ok": false, "command": "<name>", "error": {"code": "<string>", "message": "<string>", "details": {}}}`.

### 5.2 Commands

| Command | Flags | Success fields | Behavior |
|---|---|---|---|
| `describe` | — | `name`, `framework`, `runtime` | Static metadata. No side effects. |
| `prepare` | `--app-root` | — | Idempotent. For Rails: `bundle check` only (no install). If `bundle check` fails, return error `bundle_missing` — the developer runs `bundle install` once in the app-under-test. Also verifies DB cluster reachable. |
| `migrate` | `--app-root` | `schema_version` | `bin/rails db:create db:migrate`. |
| `load-dataset` | `--app-root --workload <name> --seed <n> --env KEY=VALUE [--env ...]` | `loaded_rows`, `duration_ms` | Runs `bin/rails runner 'load Rails.root.join("db/seeds.rb").to_s'` with `SEED` and all `--env` key/values propagated. `--workload` is informational. |
| `reset-state` | `--app-root --seed <n> --env KEY=VALUE [--env ...]` | — | Full reset: `bin/rails db:drop db:create db:migrate` then the same seed invocation as `load-dataset`, then `SELECT pg_stat_statements_reset()` so per-run counters start at zero (executed via `bin/rails runner`, not direct PG). Failure path must leave no half-dropped DB. |
| `start` | `--app-root` | `pid`, `base_url` | Spawns `bin/rails server` on a port the adapter picks. Returns immediately with the pid and resolved base URL. Does NOT `Process.detach`; the runner owns the lifecycle and will call `stop`. |
| `stop` | `--pid <n>` | — | Terminates the process by pid using a single coherent lifecycle (see §6.4): `SIGTERM`, poll with `Process.kill(0, pid)` + `waitpid(pid, WNOHANG)` up to 10s, escalate to `SIGKILL`, final blocking `waitpid(pid)`. Idempotent: unknown pid returns `ok: true`. |

That's the whole contract. No state-dir, no capabilities, no versioning, no health command, no base-url command, no port flag, no reset mode, no api version.

### 5.3 State handling

The runner holds all state it needs (pid, base_url) in memory between calls. It does not write adapter state to disk. If the runner crashes, orphan processes may leak; this is accepted risk for MVP. A follow-up can add a stateless "kill anything I might have started" recovery.

### 5.4 Scale fields → env vars

Workloads declare arbitrary `Scale` fields (`rows_per_table`, `open_fraction`, future `warehouses`, etc.). These are workload-specific; the adapter is workload-neutral. Transport is by generic env-var propagation:

- Runner reads `workload.scale.to_h`, separates `seed` (passed via `--seed`), uppercases remaining field names, passes each as `--env KEY=VALUE`.
- Adapter's `load-dataset` and `reset-state` inject all `--env` values into the Rails subprocess environment.
- App's `db/seeds.rb` reads whichever env vars it expects (`ROWS_PER_TABLE`, `OPEN_FRACTION`, etc.).

Example for `missing-index-todos`:
```
--seed 42 --env ROWS_PER_TABLE=10000000 --env OPEN_FRACTION=0.002
```
propagated to Rails as:
```
SEED=42 ROWS_PER_TABLE=10000000 OPEN_FRACTION=0.002 bin/rails runner 'load "db/seeds.rb"'
```

## 6. Rails Adapter

### 6.1 Implementation shape

`adapters/rails/bin/bench-adapter` is a Ruby script that parses `ARGV`, dispatches to `Commands::<Name>.new(flags).call`, emits JSON, exits. Each command class is small (~20–40 lines).

### 6.2 Subprocess conventions

- All Rails invocations via `Open3.capture3` with `chdir: app_root`.
- Environment:
  - `BUNDLE_GEMFILE=<app_root>/Gemfile`
  - `RAILS_ENV=benchmark` (expected to exist in db-specialist-demo's `database.yml`)
  - `RAILS_LOG_LEVEL=warn`
- Captured stdout/stderr from Rails subprocesses: written to `/tmp/bench-adapter-<pid>-<command>.log` for post-mortem. Not embedded in JSON response.

### 6.3 `start` semantics

1. Pick a port. Simplest: try Rails default 3000; if bound, try 3001, 3002, ... up to 3020. If all busy, return `{ok: false, error: {code: "port_exhausted", ...}}`. (Simple retry beats `bind(0)` ceremony.)
2. `spawn("bin/rails", "server", "-p", port, "-b", "127.0.0.1", chdir: app_root, ..., [:out, :err] => [logfile, "w"])`.
3. **Do NOT** call `Process.detach(pid)`. The adapter process exits after printing JSON; on Linux the Rails child is reparented to init and keeps running. Detach would install a reaper thread that races the later `stop` call's `waitpid` (producing `Errno::ECHILD`). The runner owns the lifecycle: it will call `stop --pid <n>`, which does its own non-blocking existence check via `Process.kill(0, pid)` and finishes with a blocking `waitpid(pid)` only if the process is still a child of the stopping adapter invocation (it won't be, since start and stop are separate adapter invocations — see §6.4).
4. Return `{ok, pid, base_url: "http://127.0.0.1:<port>"}` immediately. Does not wait for readiness; readiness is the runner's job (§8.2).

### 6.4 `stop` semantics

A single coherent lifecycle. Because `stop` runs in a different adapter process than `start`, the target pid is not a child of this process, so `waitpid` on it would raise `Errno::ECHILD`. The adapter therefore uses existence-checking (`kill(0, pid)`) rather than reaping:

1. `Process.kill("TERM", pid)`. If `Errno::ESRCH` (unknown pid), return `ok: true` immediately.
2. Poll every 200ms up to 10s:
   - `Process.kill(0, pid)` — if it raises `Errno::ESRCH`, the process exited; return `ok: true`.
3. Still alive after 10s: `Process.kill("KILL", pid)`, poll `kill(0, pid)` the same way for another 2s, return `ok: true` once gone.
4. If `kill(0, pid)` still succeeds after SIGKILL + 2s, return `{ok: false, error: {code: "stop_failed", ...}}`. In practice this does not happen on Linux for a Rails server.

Never call `Process.detach` in `start` or `Process.waitpid` in `stop`. Those primitives assume parent/child, which this contract does not guarantee.

### 6.5 Postgres template caching (adapter-private)

The Rails adapter caches a template database (`<dbname>_tmpl`) populated by the first full reset, and clones from it on subsequent resets. Not part of the contract — a purely adapter-internal capability. Strongly recommended for day one: without it, every reset takes minutes instead of seconds.

**Contract divergence, called out explicitly:** template operations (`CREATE DATABASE ... TEMPLATE ...`, `DROP DATABASE`) cannot be run through `bin/rails` against the current connection, and cannot target the database currently being cloned. The adapter therefore connects directly to Postgres (to the `postgres` maintenance database) as a privileged role. This is the one case where the adapter reaches Postgres outside a Rails subprocess (see §3). The connection URL comes from a dedicated env var (`BENCH_ADAPTER_PG_ADMIN_URL`) distinct from the app's `DATABASE_URL` to keep concerns separated, with a fallback to `DATABASE_URL` for local dev.

Behavior:

- First reset: `db:drop db:create db:migrate`, run seed, then (via admin connection) `CREATE DATABASE <dbname>_tmpl TEMPLATE <dbname>`.
- Subsequent resets: via admin connection, terminate other sessions on `<dbname>` (`pg_terminate_backend`), `DROP DATABASE <dbname>`, `CREATE DATABASE <dbname> TEMPLATE <dbname>_tmpl`. Then run `pg_stat_statements_reset()` via `bin/rails runner`.
- Invalidation: template is considered stale when the Rails migration version or the workload scale fields differ from what was used to build it; on mismatch, drop and rebuild the template.

## 7. Workload Contract (Ruby)

### 7.1 Base classes

```ruby
# load/lib/load/workload.rb
module Load
  class Workload
    def name             = raise NotImplementedError
    def scale            = raise NotImplementedError
    def actions          = raise NotImplementedError  # [ActionEntry, ...]
    def load_plan        = raise NotImplementedError
  end
end

# load/lib/load/action.rb
module Load
  class Action
    def initialize(rng:, ctx:, client:)
      @rng, @ctx, @client = rng, ctx, client
    end
    attr_reader :rng, :ctx, :client

    def name = raise NotImplementedError
    def call = raise NotImplementedError  # returns the HTTP response or raises
  end
end

# load/lib/load/action_entry.rb
module Load
  ActionEntry = Data.define(:action_class, :weight)
end

# load/lib/load/scale.rb
module Load
  Scale = Data.define(:rows_per_table, :open_fraction, :seed) do
    def initialize(rows_per_table:, open_fraction: nil, seed: 42)
      super
    end
  end
end

# load/lib/load/load_plan.rb
module Load
  LoadPlan = Data.define(:workers, :duration_seconds, :rate_limit, :seed) do
    def initialize(workers:, duration_seconds:, rate_limit: :unlimited, seed: nil)
      super
    end
  end
end
```

Implementor's call whether to use `Data.define` verbatim or plain classes. Field names are the contract.

### 7.2 Example workload

```ruby
# workloads/missing_index_todos/workload.rb
require "load/workload"
require_relative "actions/list_open_todos"

module Load
  module Workloads
    class MissingIndexTodos < Load::Workload
      def name = "missing-index-todos"

      def scale
        Load::Scale.new(
          rows_per_table: 10_000_000,
          open_fraction: 0.002,
          seed: 42,
        )
      end

      def actions
        [Load::ActionEntry.new(Actions::ListOpenTodos, 100)]
      end

      def load_plan
        Load::LoadPlan.new(
          workers: 16,           # parity with today's fixtures/missing-index/manifest.yml
          duration_seconds: 60,
          rate_limit: :unlimited,
        )
      end
    end
  end
end
```

```ruby
# workloads/missing_index_todos/actions/list_open_todos.rb
require "load/action"

module Load
  module Workloads
    module MissingIndexTodos
      module Actions
        class ListOpenTodos < Load::Action
          def name = :list_open_todos

          def call
            client.get("/todos/status?status=open")
          end
        end
      end
    end
  end
end
```

### 7.3 Invocation

```
bin/load run \
  --workload workloads/missing_index_todos/workload.rb \
  --adapter adapters/rails/bin/bench-adapter \
  --app-root /home/bjw/db-specialist-demo \
  [--runs-dir runs/] \
  [--startup-grace-seconds 3] \
  [--metrics-interval-seconds 5] \
  [--debug-log path]
```

The `--workload` file must `require` its action files and define exactly one class inheriting `Load::Workload`. The runner instantiates it (no args) and reads its fields.

## 8. Runner Behavior

### 8.1 Top-level flow

```
 1. Parse CLI args; validate paths exist.
 2. Load workload class from --workload; instantiate.
 3. adapter.describe → capture metadata into run record.
 4. adapter.prepare
 5. adapter.reset-state --seed <scale.seed> --env <scale fields as KEY=VALUE...>
 6. adapter.start --app-root <...>
 7. base_url = response.base_url; pid = response.pid
 8. Create run record directory: runs/<UTC_ISO>-<workload-name>/
 9. Write run.json skeleton (workload snapshot, adapter describe, pid, base_url). `window.start_ts` is intentionally omitted here — the measurement window has not started yet.
10. Readiness probe: poll `GET <base_url>/up` with exponential backoff (200ms, 400ms, 800ms, 1600ms, capped) up to --startup-grace-seconds (default 15). First 2xx response ends the probe. On timeout: adapter.stop + exit 1 with `readiness_timeout`. If the app has no `/up` (see §10.4), the workload sets `--readiness-path` or disables the probe (`--readiness-path none`, falling back to a fixed sleep).
11. Spawn N worker threads; spawn 1 metrics-reporter thread.
12. First successful worker request pins `window.start_ts` (monotonic + wall clock) and writes it into run.json. If no request succeeds before duration expires, the runner exits 3 with `outcome.start_ts: null`.
13. Run for load_plan.duration_seconds. Workers loop: select → instantiate action → call → record to in-memory metrics buffer.
14. Reporter thread: every --metrics-interval-seconds, snapshot all workers' buffers, compute per-action aggregates, append to metrics.jsonl.
15. Duration expires → signal workers to stop → drain → final metrics snapshot.
16. Write window.end_ts + outcome summary to run.json.
17. adapter.stop --pid <pid>  (always, inside an ensure block).
18. Print summary: duration, request count, error rate, run record path.
```

Signals: `SIGINT`/`SIGTERM` handled → set stop flag → `ensure` cleanup runs.

### 8.2 Readiness

The runner does a deterministic HTTP readiness probe between `start` returning and workers beginning traffic. Default path: `/up` (Rails 7.1+ default). Flags:

- `--readiness-path <path>` — override (default `/up`).
- `--readiness-path none` — disable the probe entirely; fall back to fixed sleep `--startup-grace-seconds`.
- `--startup-grace-seconds <n>` — total time budget for the probe, or sleep duration when probe is disabled. Default 15.

Probe behavior: `GET <base_url><path>`, exponential backoff (200ms, 400ms, 800ms, 1600ms, capped at 1600ms), first 2xx ends the probe. Timeout → adapter.stop + exit 1 with `readiness_timeout`.

This replaces the earlier "fixed 3s grace, record early errors as metrics" plan. Boot time varies too much (cold WSL, cold Ruby, cold Rails) to make a fixed sleep deterministic — and "early requests are errors in metrics" pollutes the very data the oracle inspects. A probe either succeeds (window is clean) or exits with a clear reason (no ambiguous run record).

### 8.3 Selector

Weighted random selection over `workload.actions` using the worker's seeded RNG. Implementor's call on the algorithm (cumulative-weight binary search, or repeated `Array#sample` with weights). Each worker has its own `rng`, so selection is per-worker-deterministic given the seed.

### 8.4 Rate limiter

Port today's `Fixtures::MissingIndex::Drive::RateLimiter` to `Load::RateLimiter`. Shared across workers (single mutex, single `@next_allowed_at`). `:unlimited` → no-op. Numeric rate-limit (req/sec total) → spaced at `1.0/rate`.

### 8.5 Action invocation

```ruby
entry = selector.next            # ActionEntry
action = entry.action_class.new(rng: rng, ctx: ctx, client: client)
started_ns = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
begin
  response = action.call
  metrics_buffer.record_ok(action: action.name, latency_ns: now_ns - started_ns, status: response.code.to_i)
rescue => e
  metrics_buffer.record_error(action: action.name, latency_ns: now_ns - started_ns, error_class: e.class.name)
end
```

Workers never raise out of the loop. Errors become recorded events in the metrics buffer.

### 8.6 Metrics buffering and reporting

Each worker owns a per-action in-memory buffer:
```ruby
# MetricsBuffer:
#   {action_name => { ok_latencies_ns: [...], error_counts: { error_class => count } }}
```

The reporter thread every `--metrics-interval-seconds`:

1. Snapshots all workers' buffers (synchronized swap — each worker swaps its buffer for a fresh empty one).
2. Merges per-action arrays across workers.
3. Computes per-action aggregates: `count`, `error_count`, `p50_ms`, `p95_ms`, `p99_ms`, `max_ms` (exact percentiles via `sort` — per-interval sizes are small enough).
4. Appends one line per interval to `metrics.jsonl`.

Final interval (on stop) runs the same snapshot-merge-compute-append once more so no tail data is lost.

**`metrics.jsonl` format:**
```json
{"ts":"2026-04-19T14:32:05.000Z","interval_ms":5000,"actions":{"list_open_todos":{"count":4500,"error_count":2,"errors_by_class":{"Net::ReadTimeout":2},"p50_ms":12.3,"p95_ms":34.1,"p99_ms":87.2,"max_ms":204.5,"status_counts":{"200":4498,"500":0}}}}
```

**Debug logging (off by default):** `--debug-log <path>` or `--debug-log -` (stderr) enables per-request lines written to the specified sink. Format is a single-line human-readable log:
```
2026-04-19T14:32:00.456Z w=2 list_open_todos GET /todos/status?status=open 200 18.2ms
```
Never enabled for production runs. Intended for implementor debugging and for running one-off diagnostic loads.

## 9. Run Record Layout

```
runs/<UTC_ISO_TIMESTAMP>-<workload-name>/
  run.json                 # metadata
  metrics.jsonl            # per-interval per-action aggregates
  adapter-commands.jsonl   # one line per adapter CLI invocation
```

No `requests.jsonl`, no `state-dir/`, no `plans/`, no `signals.json`.

### 9.1 `run.json`

```json
{
  "run_id": "2026-04-19T14-32-00Z-missing-index-todos",
  "workload": {
    "name": "missing-index-todos",
    "file": "workloads/missing_index_todos/workload.rb",
    "scale": {"rows_per_table": 10000000, "open_fraction": 0.002, "seed": 42},
    "load_plan": {"workers": 16, "duration_seconds": 60, "rate_limit": "unlimited", "seed": null},
    "actions": [{"class": "Load::Workloads::MissingIndexTodos::Actions::ListOpenTodos", "weight": 100}]
  },
  "adapter": {
    "describe": {"name": "rails-postgres-adapter", "framework": "rails", "runtime": "ruby-3.3"},
    "bin": "adapters/rails/bin/bench-adapter",
    "app_root": "/home/bjw/db-specialist-demo",
    "base_url": "http://127.0.0.1:3000",
    "pid": 48291
  },
  "window": {
    "start_ts": "2026-04-19T14:32:03.417Z",
    "end_ts":   "2026-04-19T14:33:03.422Z",
    "readiness": {"path": "/up", "probe_duration_ms": 2893, "probe_attempts": 5},
    "startup_grace_seconds": 15,
    "metrics_interval_seconds": 5
  },
  "outcome": {
    "requests_total": 14302,
    "requests_ok": 14300,
    "requests_error": 2,
    "aborted": false
  }
}
```

Written incrementally: skeleton (no `window.start_ts`) at step 9 of §8.1; `window.readiness` at step 10; `window.start_ts` at step 12 (first successful request); `window.end_ts` and `outcome` at step 16.

### 9.2 `adapter-commands.jsonl`

```json
{"ts":"...","command":"prepare","args":["--app-root","/..."],"exit_code":0,"duration_ms":1234,"stdout_json":{"ok":true},"stderr":""}
```

Captures every adapter CLI invocation, duration, output. Primary debugging surface when a run fails.

## 10. db-specialist-demo Changes (External Repo)

### 10.1 `config/database.yml`

Add a `benchmark` environment (if absent). Adapter sets `RAILS_ENV=benchmark`.

### 10.2 `db/seeds.rb`

Parameterized:

```ruby
# db/seeds.rb
rows_per_table = Integer(ENV.fetch("ROWS_PER_TABLE", "10000"))
seed_value     = Integer(ENV.fetch("SEED", "42"))
open_fraction  = Float(ENV.fetch("OPEN_FRACTION", "0.002"))

ActiveRecord::Base.connection.execute(<<~SQL)
  -- Port the body of today's fixtures/missing-index/setup/02_seed.sql here,
  -- interpolating the numeric values above.
  -- These come from the adapter's --env flags (see §5.4).
  -- They are adapter-controlled numeric values; interpolation is safe.
SQL
```

Env var names must match **uppercased Scale field names** (§5.4). `Scale(rows_per_table:, open_fraction:, seed:)` → `ROWS_PER_TABLE`, `OPEN_FRACTION`, `SEED`.

Implementor's job: migrate the body of today's `fixtures/missing-index/setup/02_seed.sql` into this form. Seed must remain fast (PG-level `generate_series`), not ActiveRecord row-by-row.

### 10.3 Migrations

Confirm db-specialist-demo's existing Rails migrations produce a `todos` table matching today's `fixtures/missing-index/setup/01_schema.sql` (no index on `status`). Align Rails migration or document the drift.

### 10.4 Health endpoint

Used by the runner's readiness probe (§8.2). Rails 7.1+ ships `/up` by default and returns 200 once the app has booted. If the app-under-test is pre-7.1 or has disabled `/up`, either (a) re-enable it (one-line `Rails.application.routes.draw` addition), or (b) point the workload at a different idempotent GET endpoint via `--readiness-path`, or (c) set `--readiness-path none` to fall back to a fixed grace sleep. The probe is deterministic where the old fixed-sleep plan was not.

### 10.5 No other changes

No `/__bench` routes, no benchmark controllers, no stats endpoints, no middleware.

## 11. Oracle Script (Tactical, Workload-Local)

`workloads/missing_index_todos/oracle.rb`:

```
Usage: ruby workloads/missing_index_todos/oracle.rb <run-record-dir> \
  [--database-url postgresql://...]     # defaults to DATABASE_URL env
  [--clickhouse-url http://...]         # defaults to CLICKHOUSE_URL env
```

Accepts `--database-url` and `--clickhouse-url` flags with env-var fallbacks. Does not parse `database.yml`.

Behavior (ported from today's `fixtures/missing-index/validate/assert.rb`, with robustness fixes):

1. Read `run.json` for the window (`start_ts`, `end_ts`, workload fingerprint).
2. Connect to PG; run `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT * FROM todos WHERE status = 'open'`. Walk the JSON plan tree recursively and assert that *some* scan node on relation `todos` has `Node Type == "Seq Scan"`. Do NOT rely on the root node's shape: the Rails action may wrap the scan under a `Limit`, `Gather`, or `Sort` node depending on Rails query construction. Rejection cases to flag: any `Index Scan` / `Index Only Scan` / `Bitmap Index Scan` on `todos` (these indicate the missing index has been added).
3. Identify the target statement by ClickHouse `queryid` fingerprint (the `pg_stat_statements.queryid` column), NOT by `SQL LIKE '%todos%status%'` text matching. The runner records the expected queryid into `run.json` at seed time by running the canonical EXPLAIN in step 2 and reading back `pg_stat_statements.queryid` for that statement's normalized form. If multiple queryids match the same normalized text (parameter-variant queries), the oracle sums `total_exec_count` across them for the window.
4. Poll ClickHouse for the window until `sum(total_exec_count) >= 500` for the queryid set, or timeout (default 30s past `window.end_ts`). Timeout → print `FAIL: clickhouse (saw N calls before timeout)`, exit 1.
5. Print `PASS: explain ...` / `PASS: clickhouse ...`, exit 0. On mismatch: print `FAIL:` with observed vs expected, exit 1.

**Why this matters:** text-matching `SQL LIKE` is fragile across Rails versions (AR sometimes emits `"todos"."status"` quoted differently) and across normalization changes in pg_stat_statements. queryid is the stable identifier. Tree-walking instead of root-matching survives minor plan-shape changes like `Gather`/`Limit` wrappers that the current `assert.rb` trips over when Postgres parallel workers kick in.

Not wired into the runner. Runner exits cleanly regardless. When workloads stabilize or LLM tooling takes over, delete the script.

## 12. `bin/load` CLI

```
bin/load run --workload <path> --adapter <path> --app-root <path> \
  [--runs-dir runs/] [--startup-grace-seconds 15] \
  [--readiness-path /up | --readiness-path none] \
  [--metrics-interval-seconds 5] [--debug-log <path|->]
bin/load --version
bin/load --help
```

Exit codes:
- `0`: run completed, at least one successful request
- `1`: adapter error (startup/readiness/shutdown/lifecycle) — includes `readiness_timeout`
- `2`: workload load error (file missing / no Workload subclass defined)
- `3`: no successful requests during the window (degenerate run)

## 13. MVP Parity Target

Against a freshly-started docker-compose stack + db-specialist-demo on its default branch:

```
docker compose up -d postgres clickhouse collector
bin/load run \
  --workload workloads/missing_index_todos/workload.rb \
  --adapter adapters/rails/bin/bench-adapter \
  --app-root ~/db-specialist-demo
ruby workloads/missing_index_todos/oracle.rb runs/<latest>
```

Must print `PASS: explain` and `PASS: clickhouse`.

Against `oracle/add-index` branch of db-specialist-demo, must print `FAIL: explain (expected Seq Scan, got Index Scan)`.

## 14. Testing Strategy

### 14.1 Runner (`/load/test/`)

- `RateLimiter` — port today's tests (`:unlimited` never sleeps; finite rate spaces at `1/rate`).
- `Selector` — weighted picks converge to target distribution over large-N with seeded RNG.
- `MetricsBuffer` — thread-safe swap semantics, accurate percentile computation on known data.
- `Reporter` — snapshots at configured interval using a fake clock; final snapshot captures tail data.
- `AdapterClient` — stubbed `Open3.capture3`; validates arg construction, JSON parsing, error shape.
- `Worker` — runs for a fixed fake duration; records expected number of events.

### 14.2 Rails adapter (`/adapters/rails/test/`)

- Per-command unit tests with stubbed `Open3` (validate subprocess args, env, chdir).
- One integration test running against a real `bin/rails` in a scratch Rails app fixture: `prepare → migrate → load-dataset → start → <HTTP GET /up works> → stop`. **Opt-in** via `RUN_RAILS_INTEGRATION=1`. Default CI run skips it (no Ruby + Rails stack guaranteed on all dev machines); nightly / pre-release runs set the flag.

### 14.3 End-to-end against db-specialist-demo

A skip-by-default integration test gated on `RUN_DB_SPECIALIST_DEMO_INTEGRATION=1` plus `DB_SPECIALIST_DEMO_PATH=<path>`. Runs the §13 parity sequence against the real external app at a pinned commit SHA (recorded in plan Task 7, not in this spec — spec is reference-implementation-agnostic). Without the env gate the test no-ops with a clear skip message. This replaces any in-spec "toy integration test" — the runner is exercised against the real target app or it isn't exercised end-to-end.

### 14.4 Manual smoke

`make load-smoke` target that assumes `docker compose up -d` and `~/db-specialist-demo` are ready, runs the §13 parity sequence.

## 15. Implementor Decisions (Document What You Chose)

1. Worker concurrency primitive (threads vs `Thread.new` pool vs a concurrent lib).
2. HTTP client (`Net::HTTP`, `Net::HTTP::Persistent`, `httprb`).
3. Exact shape of `ctx` hash passed into actions (start minimal: `{base_url, worker_id}`).
4. JSON library (stdlib is fine).
5. Template caching (§6.5) ships day one. Implementor's decision: exact shape of template invalidation (migration-version hash, scale-fields hash, both). Also: `BENCH_ADAPTER_PG_ADMIN_URL` resolution — env var primary, `DATABASE_URL` fallback, explicit error if neither set.
6. Percentile algorithm (exact sort is fine for MVP interval sizes; note if switching to HDR later).
7. Buffer-swap synchronization (mutex + swap, or lock-free ring). Mutex + swap is fine.

## 16. Out of Scope

- Express / Dropwizard adapters
- Additional workloads (TPC-C, YCSB, N+1, lock contention)
- LLM patch application / optimization loop automation
- Soft / dataset reset modes
- Run comparison tooling
- Declarative signal library
- Workload spec versioning, adapter versioning, capability negotiation
- Per-request on-disk trace
- State-dir protocol / orphan-process recovery
- Readiness probing as a contract primitive
- Distributed runners, remote adapters, multi-host

## 17. Risks

1. **Rails boot time vs readiness probe budget.** Default 15s probe budget (§8.2) covers a cold Rails 7 boot with margin. Slower apps override via `--startup-grace-seconds`. On timeout the runner exits 1 with `readiness_timeout` rather than producing a noisy run record with early-error pollution.
2. **Seed performance.** Minutes-per-reset without template caching. Strongly recommend template caching (§6.5) on day one.
3. **`benchmark` Rails env assumption.** If db-specialist-demo doesn't have one, implementor adds it. Coordinate.
4. **Existing fixture harness is committed on this branch.** Section 4 deletions are real. Don't leave the old code alongside the new.
5. **ClickHouse data delay.** Collector scrape interval means run-end ClickHouse data is late by up to scrape-interval seconds. Oracle script's polling loop handles this.
6. **Orphaned Rails processes on runner crash.** Accepted for MVP. Manual `pkill -f 'rails server'` is the recovery path until follow-up adds pid persistence.
7. **Port collision.** Adapter picks among 3000–3020. If all busy, `start` fails. Accepted; extend range in a follow-up if it happens.
8. **In-memory metrics OOM on very long runs.** Each per-interval bucket caps at `workers * rate * interval` latency samples (e.g., 4 workers × 500 req/s × 5s = 10k samples ≈ negligible). Not a concern at MVP scale.

## 18. Acceptance Checklist

- [ ] `bin/fixture`, `fixtures/missing-index/`, `collector/lib/fixtures/`, `collector/test/fixtures/`, `load/harness.rb`, old `load/README.md`, `fixture-harness-walkthrough.md` all deleted.
- [ ] `/load/`, `/workloads/missing_index_todos/`, `/adapters/rails/`, `/bin/load` created per §4.
- [ ] `bin/load run ...` drives the full lifecycle and produces a run record matching §9.
- [ ] `~/db-specialist-demo` changes landed (benchmark env, parameterized `db/seeds.rb`).
- [ ] `ruby workloads/missing_index_todos/oracle.rb runs/<latest>` prints PASS against default branch.
- [ ] Same oracle prints FAIL against `oracle/add-index` branch.
- [ ] Runner test suite green (§14.1).
- [ ] Rails adapter test suite green (§14.2).
- [ ] `make load-smoke` documented in root README.

## 19. Glossary

- **Run record**: directory on disk containing one load run's artifacts (§9).
- **Action**: Ruby class implementing one HTTP interaction (§7.1).
- **Workload**: Ruby class declaring name + scale + actions + load_plan (§7.1).
- **Adapter**: CLI program mediating app lifecycle via framework-native tools (§5).
- **Oracle script**: tactical, per-workload verifier that reads a run record and prints PASS/FAIL (§11).
- **Collector**: this repo's existing Postgres → ClickHouse scraper. Out of scope.
