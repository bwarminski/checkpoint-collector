# Checkpoint Collector

This repo owns the collector pipeline, ClickHouse DDLs, the local Postgres and
ClickHouse stack, and the load runner used to generate benchmark traffic
against external apps.

## Local Run

```bash
docker compose up -d --build
make test
make load-smoke
```

`make test` is the local code-level verification target. It runs:

- `make test-load`
- `make test-adapters`
- `make test-workloads`
- `make test-adapters-integration` when you want the opt-in Rails integration coverage

Those targets cover the load runner, the Rails adapter, and the
`missing-index-todos` workload/oracle. The adapter suite includes the existing
opt-in integration coverage, so the default run still reports the two expected
skips unless you explicitly enable those integration tests.

`make test-adapters-integration` runs both adapter integration cases through
separate targets with the env each one needs:

- `make test-adapters-fixture-integration`
  - runs the fixture Rails app under `adapters/rails/test/fixtures/demo_app`
  - exports `RUN_RAILS_INTEGRATION=1`
- `make test-adapters-demo-integration`
  - runs the real `~/db-specialist-demo` path
  - exports `RUN_DB_SPECIALIST_DEMO_INTEGRATION=1`
  - exports `DB_SPECIALIST_DEMO_PATH=/home/bjw/db-specialist-demo`
  - exports `DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo`
  - exports `BENCH_ADAPTER_PG_ADMIN_URL=postgres://postgres:postgres@localhost:5432/postgres`

The split matters because the fixture app is SQLite-backed while the real demo
integration needs the Postgres benchmark URLs.

`make load-smoke` is different. It is the environment-dependent end-to-end path
against `~/db-specialist-demo`, local Postgres, ClickHouse, and the collector
stack. Use `make test` to verify the branch logic; use `make load-smoke` to see
whether the current dataset, app settings, and workload shape still behave
acceptably together.

The operator commands map directly to `bin/load`:

```bash
bin/load verify-fixture --workload missing-index-todos \
  --adapter adapters/rails/bin/bench-adapter \
  --app-root /home/bjw/db-specialist-demo

bin/load soak --workload missing-index-todos \
  --adapter adapters/rails/bin/bench-adapter \
  --app-root /home/bjw/db-specialist-demo
```

## Load Runner

The top-level entrypoint is `bin/load run`, which combines a workload, an
adapter, and an app root:

```bash
DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo \
BENCH_ADAPTER_PG_ADMIN_URL=postgres://postgres:postgres@localhost:5432/postgres \
bin/load run --workload missing-index-todos \
  --adapter adapters/rails/bin/bench-adapter \
  --app-root /home/bjw/db-specialist-demo
```

`make load-smoke` runs that command against `~/db-specialist-demo`. It assumes
`docker compose up -d` is already running in this repo and the demo app is
available for the adapter to prepare, seed, start, and stop during the run.

### Run Modes

`bin/load` has three operator-facing modes. They use the same workload and
adapter contract, but they answer different questions.

#### `bin/load run`

Use `run` for a finite benchmark window. This is the mode behind
`make load-smoke`.

```bash
DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo \
BENCH_ADAPTER_PG_ADMIN_URL=postgres://postgres:postgres@localhost:5432/postgres \
bin/load run --workload missing-index-todos \
  --adapter adapters/rails/bin/bench-adapter \
  --app-root /home/bjw/db-specialist-demo
```

Intent:

- prove the current fixture still reproduces the missing-index path
- produce one bounded run directory under `runs/`
- feed the workload-local oracle a stable `run.json` and `query_ids` set

What it writes:

- `run.json`
- `metrics.jsonl`
- `adapter-commands.jsonl`

What success looks like:

- the command exits `0`
- `run.json` has a full window with `start_ts` and `end_ts`
- the oracle passes against the produced run directory

What "oracle" means here:

- the oracle is the workload-specific verifier that judges whether a completed run reproduced the intended pathology
- it is not the load generator itself; it reads the run artifacts after `bin/load run` finishes
- for `missing-index-todos`, the oracle checks the target query family's plan shape and ClickHouse evidence, then returns `PASS` or `FAIL`

Sample finite-run artifact:

```json
{
  "run_id": "20260425T155137Z-missing-index-todos",
  "outcome": {
    "requests_total": 1086,
    "requests_ok": 1060,
    "requests_error": 26,
    "aborted": false
  },
  "query_ids": ["-6140164853592117657"],
  "warnings": [],
  "invariant_samples": []
}
```

Sample oracle output:

```text
PASS: explain (Seq Scan on todos, plan node confirmed)
PASS: clickhouse (720 calls; mean 38.1ms)
PASS: dominance (4.54x over next queryid)
```

#### `bin/load soak`

Use `soak` for a long-running diagnosis session. It keeps generating traffic
until you interrupt it or the invariant sampler aborts because the dataset has
drifted out of the designed regime.

```bash
DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo \
BENCH_ADAPTER_PG_ADMIN_URL=postgres://postgres:postgres@localhost:5432/postgres \
bin/load soak --workload missing-index-todos \
  --adapter adapters/rails/bin/bench-adapter \
  --app-root /home/bjw/db-specialist-demo
```

Intent:

- keep background traffic flowing for live diagnosis
- preserve the same mixed query families as `run`
- record invariant samples so long-running drift is visible in the run record

What it writes:

- `run.json`
- `metrics.jsonl`
- `adapter-commands.jsonl`
- `run.json.invariant_samples`

Healthy soak behavior:

- the command keeps running until you send `SIGINT`/`SIGTERM`
- `run.json` is updated throughout the run
- `invariant_samples` stays empty until the first 60s sample lands, then grows
  one entry per sample

Invariant-breach stop behavior:

- three consecutive breach samples stop the run with non-zero exit
- `run.json.outcome.error_code` becomes `"invariant_breach"`
- `warnings` and `invariant_samples` both show the breach trail

Sample degraded-soak artifact:

```json
{
  "run_id": "20260425T154248Z-missing-index-todos",
  "outcome": {
    "requests_total": 4842,
    "requests_ok": 4790,
    "requests_error": 52,
    "aborted": true,
    "error_code": "invariant_breach"
  },
  "warnings": [
    {
      "type": "invariant_breach",
      "message": "open_count 0 is below open_floor 30000; total_count 0 is below total_floor 80000"
    }
  ],
  "invariant_samples": [
    {
      "sampled_at": "2026-04-25 15:44:02 UTC",
      "open_count": 0,
      "total_count": 0,
      "breach": true
    }
  ]
}
```

#### `bin/load verify-fixture`

Use `verify-fixture` when you want the fast pre-flight pathology check without
running a benchmark window. This is also the gate that `run` and `soak` execute
before workers start for `missing-index-todos`.

```bash
DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo \
BENCH_ADAPTER_PG_ADMIN_URL=postgres://postgres:postgres@localhost:5432/postgres \
bin/load verify-fixture --workload missing-index-todos \
  --adapter adapters/rails/bin/bench-adapter \
  --app-root /home/bjw/db-specialist-demo
```

Intent:

- confirm the app still exposes the three expected pathologies
- fail early before a benchmark run starts if the fixture has silently rotted

What it does:

- runs adapter `describe`, `prepare`, `reset-state`, `start`, readiness, verify,
  and `stop`
- does not create worker traffic
- does not write a run directory

What success looks like:

- exit `0`
- no output on success by default

What failure looks like:

- exit `2`
- stderr explains which fixture contract failed

Representative failure shape:

```text
fixture verification failed for /api/todos/counts: expected at least 10 count calls for 10 users, saw 2
```

#### Quick Comparison

| Mode | Runs workers | Writes run dir | Uses oracle later | Uses invariant sampler |
|---|---|---|---|---|
| `run` | yes | yes | yes | no |
| `soak` | yes | yes | usually no, unless you inspect it later | yes |
| `verify-fixture` | no | no | no | no |

## Manual Exploration

If `make load-smoke` times out or exits `3`, the fastest way to understand why
is to separate:

- database reset and seeding
- app startup
- one request latency
- parallel request latency

The runner does not expose scale overrides yet, so manual experiments should go
through the Rails adapter directly.

### 1. Reset the benchmark database with a chosen seed size

This example uses a smaller dataset than the default workload:

```bash
DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo \
BENCH_ADAPTER_PG_ADMIN_URL=postgres://postgres:postgres@localhost:5432/postgres \
adapters/rails/bin/bench-adapter --json reset-state \
  --app-root /home/bjw/db-specialist-demo \
  --workload missing-index-todos \
  --seed 42 \
  --env ROWS_PER_TABLE=1000000 \
  --env OPEN_FRACTION=0.002
```

Change `ROWS_PER_TABLE`, `OPEN_FRACTION`, and `SEED` to try other scenarios.

Useful sanity check after reset:

```bash
docker compose exec postgres psql -U postgres -d checkpoint_demo -c \
  "select count(*) as open_count from todos where status = 'open';"
```

### 2. Start the app under the adapter

```bash
DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo \
BENCH_ADAPTER_PG_ADMIN_URL=postgres://postgres:postgres@localhost:5432/postgres \
adapters/rails/bin/bench-adapter --json start \
  --app-root /home/bjw/db-specialist-demo
```

That returns a `pid` and `base_url`. Keep both.

Check readiness:

```bash
curl -i http://127.0.0.1:3000/up
```

### 3. Measure one request

```bash
curl -sS -o /tmp/status.json \
  -w 'code=%{http_code} total=%{time_total} size=%{size_download}\n' \
  'http://127.0.0.1:3000/todos/status?status=open'
```

This tells you whether the endpoint is fundamentally slow even without queueing.
If you want a quick payload-size check:

```bash
wc -c /tmp/status.json
```

### 4. Measure parallel requests

This is the simplest way to see whether queueing pushes the tail past the
runner's HTTP timeout:

```bash
seq 1 16 | xargs -I{} -P16 bash -lc \
  "curl -sS -o /dev/null -w '%{time_total}\n' \
  'http://127.0.0.1:3000/todos/status?status=open'" | sort -n
```

Change `-P16` to try different concurrency levels. A useful progression is:

- `-P1` for single-request latency
- `-P4` for modest concurrency
- `-P8`
- `-P16` to match the current workload

If the tail climbs above the client's read timeout, `bin/load run` will record
`Net::ReadTimeout` even if Postgres itself is still responding.

### 5. Inspect what the last run did

```bash
latest=$(ls -1dt runs/* | head -n1)
sed -n '1,220p' "$latest/run.json"
tail -n 20 "$latest/metrics.jsonl"
cat "$latest/adapter-commands.jsonl"
```

Each run directory contains:

- `run.json`
  - the canonical run summary
  - records the effective workload scale, load plan, adapter metadata, readiness timing, query IDs, and final outcome
  - use this first to answer "did the run actually start?", "did any requests succeed?", and "what dataset and workload shape did I just run?"
- `metrics.jsonl`
  - interval snapshots of request outcomes during the load window
  - each line is one reporting interval with per-action counts, percentiles, status counts, and error classes
  - use this to answer "when did the run go bad?" and "was the failure immediate, intermittent, or only in the tail?"
- `adapter-commands.jsonl`
  - one line per adapter lifecycle command
  - records `describe`, `prepare`, `reset-state`, `start`, and `stop` timing and results
  - use this to answer "did time go into reset, startup, or load generation?"

Useful signals:

- `run.json`:
  - `adapter.base_url` and `adapter.pid` set means startup succeeded
  - `window.start_ts` set means at least one request succeeded
  - `outcome.requests_error` and `outcome.error_code` tell you how the run failed
  - `workload.scale.rows_per_table` and `workload.scale.open_fraction` tell you exactly which dataset size the run used
  - `query_ids` tells the oracle which statement family the run was targeting
- `metrics.jsonl`:
  - empty `actions` objects early in the file usually mean the run is still in readiness or workers are blocked before first completion
  - `Net::ReadTimeout` means the app did not finish responses before the HTTP client gave up
  - high `p95_ms` and `p99_ms` with low or zero error count means the app is degrading but still completing
  - a sharp shift from successful intervals to all-error intervals usually means saturation or queueing, not a seeding problem
- `adapter-commands.jsonl`:
  - shows whether the time went into `reset-state`, `start`, or the load window
  - a very long `reset-state` usually means template rebuild or large seed work
  - a short `start` plus many request failures means the app booted, but the endpoint could not keep up with the workload

### 6. Compare app time vs database time

If requests time out but you suspect the database is still fine, compare the app
path with the database's view of the query:

```bash
docker compose exec postgres psql -U postgres -d checkpoint_demo -c \
  "select queryid::text, calls, mean_exec_time, query
   from pg_stat_statements
   where query like '%todos%'
   order by calls desc
   limit 10;"
```

If Postgres shows sub-second or low-single-digit-second execution while the HTTP
client times out, the bottleneck is probably in app-side queueing, object
materialization, or JSON rendering rather than the SQL itself.

### 7. Stop the app when finished

```bash
DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo \
BENCH_ADAPTER_PG_ADMIN_URL=postgres://postgres:postgres@localhost:5432/postgres \
adapters/rails/bin/bench-adapter --json stop --pid <pid>
```
