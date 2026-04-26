# Collector Target Validation Design

## Problem

PlanetScale soak runs need ClickHouse evidence from the collector, but `make load-soak-planetscale` does not start or validate a collector. A stale Docker Compose collector can keep running against local Postgres while the soak runner talks to PlanetScale, which makes ClickHouse evidence misleading.

## Goals

- Add a repeatable validation command that proves the collector can poll a selected Postgres target and write fresh rows to ClickHouse.
- Support both local Docker Postgres and PlanetScale Postgres through the same validation logic.
- Expose operator-friendly make targets for local Postgres and PlanetScale validation.
- Make validation deterministic by issuing a harmless SQL statement before the collector pass so `pg_stat_statements` has a fresh row to collect.

## Non-Goals

- Do not start or manage a long-running collector process.
- Do not kill or replace an existing Docker Compose collector.
- Do not run a load soak as part of collector validation.
- Do not add PlanetScale branch creation or PlanetScale logs/Insights ingestion.

## Architecture

Add a small validator executable that:

1. Reads `POSTGRES_URL` and `CLICKHOUSE_URL`.
2. Optionally enforces stats-only mode.
3. Connects to Postgres and verifies `pg_stat_statements` is readable.
4. Runs a harmless validation query with a stable SQL comment.
5. Captures ClickHouse `query_events` and `collector_state` baselines.
6. Runs one `CollectorRuntime#run_once_pass`.
7. Verifies `collector_state` advanced and a `query_events` row for the validation query comment appeared after the baseline.

The validator should call the existing collector runtime instead of duplicating collector polling behavior. The make targets only configure environment and mode.

## Make Targets

`make validate-collector-postgres` validates whichever Postgres is in `POSTGRES_URL`.

`make validate-collector-planetscale` uses `BENCH_ADAPTER_PG_ADMIN_URL` when present, falls back to `POSTGRES_URL`, and forces stats-only mode by setting `COLLECTOR_DISABLE_LOG_INGESTION=1`.

Both targets default `CLICKHOUSE_URL` to `http://localhost:8123` when it is not exported.

## Failure Behavior

Validation exits non-zero with a clear message when:

- `POSTGRES_URL` is missing.
- `CLICKHOUSE_URL` is missing and no target default supplies it.
- ClickHouse is unreachable.
- `pg_stat_statements` is unavailable or unreadable.
- stats-only mode is required but log ingestion is enabled.
- the collector pass does not advance `collector_state`.
- the validation query is not visible in `query_events` after the pass.

## Testing

Unit tests should cover:

- missing environment failures
- stats-only enforcement
- Postgres validation query execution
- ClickHouse baseline and post-pass checks
- failure when `collector_state` does not advance
- failure when the validation query evidence is absent
- make targets exposing both local and PlanetScale validation paths

Live validation remains an operator step because it needs a real Postgres target and ClickHouse.
