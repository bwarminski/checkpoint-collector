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

Those targets cover the load runner, the Rails adapter, and the
`missing-index-todos` workload/oracle. The adapter suite includes the existing
opt-in integration coverage, so the default run still reports the two expected
skips unless you explicitly enable those integration tests.

`make load-smoke` is different. It is the environment-dependent end-to-end path
against `~/db-specialist-demo`, local Postgres, ClickHouse, and the collector
stack. Use `make test` to verify the branch logic; use `make load-smoke` to see
whether the current dataset, app settings, and workload shape still behave
acceptably together.

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
