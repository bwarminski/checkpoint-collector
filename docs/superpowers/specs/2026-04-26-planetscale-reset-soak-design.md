# PlanetScale Reset/Soak Design

## Context

The current load soak path works against the local Docker Compose stack. It assumes:

- local Postgres can create/drop benchmark databases
- the Rails adapter can cache seeded template databases
- the collector can read a Docker-mounted Postgres JSON log file
- `pg_stat_statements` is available and resettable before each run

PlanetScale Postgres changes those assumptions. The first PlanetScale pass will target an existing branch and will reset/reseed that branch before a run. Branch-per-run automation and remote log ingestion are deferred.

## Goals

- Run `bin/load soak` against an existing PlanetScale Postgres branch.
- Reset and reseed the remote database before workers start.
- Preserve the local Docker reset path unchanged.
- Poll `pg_stat_statements` into ClickHouse for PlanetScale runs.
- Disable local Postgres log ingestion for PlanetScale runs.
- Keep credentials in environment variables and out of committed files.

## Non-Goals

- Create or delete PlanetScale branches per run.
- Stream PlanetScale Cluster Logs into the collector.
- Replace PlanetScale Query Insights or pganalyze.
- Add a second load runner.
- Add backward-compatibility aliases for old command names or env names.

## Operator Model

PlanetScale soak uses the same top-level command shape as local soak:

```bash
DATABASE_URL=postgresql://...:5432/... \
BENCH_ADAPTER_PG_ADMIN_URL=postgresql://...:5432/... \
POSTGRES_URL=postgresql://...:5432/... \
COLLECTOR_DISABLE_LOG_INGESTION=1 \
bin/load soak --workload missing-index-todos \
  --adapter adapters/rails/bin/bench-adapter \
  --app-root /home/bjw/db-specialist-demo
```

`DATABASE_URL` is the app runtime connection. The validated checkpoint uses a direct connection on port `5432`.

`BENCH_ADAPTER_PG_ADMIN_URL` is the direct connection used by adapter setup and stats operations. For PlanetScale this should use port `5432`.

`POSTGRES_URL` is the collector stats polling connection. For this pass, use a direct connection on port `5432`.

Remote reset/reseed is destructive to the target database. Operators must point these env vars at a branch intended for benchmark data, not a production branch.

## Rails Adapter Reset Strategy

Add an explicit reset strategy to the Rails adapter.

The default strategy remains local and keeps the current template cache behavior:

- drop/create the benchmark database
- load schema
- seed data
- create/reset `pg_stat_statements`
- capture workload query IDs

The PlanetScale strategy will avoid database-level clone operations and will reset the existing database contents through the benchmark app's schema/seeding commands:

- load the benchmark schema into the existing database
- reseed using the workload scale env
- ensure `pg_stat_statements` exists
- capture workload query IDs
- reset `pg_stat_statements`

Selection should be explicit, not guessed from hostname. A clear env var such as `BENCH_ADAPTER_RESET_STRATEGY=remote` is enough for this pass.

The remote strategy should reuse the existing adapter command runner and workload scale contract. It should not introduce PlanetScale-specific code into the load runner.

## Collector Stats-Only Mode

Add a collector runtime option that skips log ingestion while still polling `pg_stat_statements`.

When disabled, log ingestion should not try to read `POSTGRES_LOG_PATH` and should not write `postgres_logs`. The collector should still write:

- `query_events`
- `collector_state`

Local Docker behavior remains unchanged when the flag is absent.

## Query Evidence

The first PlanetScale implementation uses `pg_stat_statements` as the query evidence source. PlanetScale Cluster Logs and Query Insights are valuable, but they are not required for reset/reseed soak.

Fast follow: evaluate PlanetScale Cluster Logs, Query Insights, `pginsights`, and the pganalyze log integration as a remote query-log evidence source.

## Error Handling

Remote reset failures should fail before the load window starts and should surface as adapter errors in `run.json`.

The adapter should preserve the existing JSON error contract. Error messages should identify the failing phase:

- schema load
- seed
- extension setup
- query ID capture
- stats reset

The collector stats-only flag should be visible in logs or startup output only if there is already a local logging pattern for runtime configuration. It should not add noisy per-interval output.

## Tests

Use TDD for implementation.

Focused tests:

- Rails adapter reset-state selects the local strategy by default.
- Rails adapter reset-state selects the remote strategy when requested.
- Remote strategy does not call template-cache create/drop/clone methods.
- Remote strategy runs schema load, seeding, extension setup, query ID capture, and stats reset in order.
- Collector runtime skips log ingestion when stats-only mode is enabled.
- Collector runtime still polls `pg_stat_statements` when stats-only mode is enabled.
- Existing local adapter and collector tests remain green.

No tests should hit a real PlanetScale database. Live verification can be a manual operator step after unit and integration tests pass locally.

## Documentation

Update the README with a PlanetScale soak section that covers:

- required PlanetScale setup: `pg_stat_statements` enabled in the dashboard and installed in the database
- required env vars
- expected direct vs pooled connection usage
- collector stats-only mode
- branch-per-run and logs/Insights as future work

## Future Work

- Optional PlanetScale branch-per-run creation and cleanup.
- Remote query-log ingestion through PlanetScale Logs, Query Insights, `pginsights`, or pganalyze-compatible APIs.
- A safer operator wrapper that validates the target branch before destructive reset/reseed.
