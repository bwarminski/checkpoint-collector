# Collector Correctness and Query Model Design

## Summary

This design improves collector correctness and interval reporting in four areas:

- Replace drift-prone `run_once` plus `sleep interval` scheduling with a fixed-interval, start-based scheduler.
- Replace lossy `pg_stat_activity LIMIT 1` sample lookup with raw Postgres JSON log ingestion keyed by `query_id`.
- Store normalized statement text from `pg_stat_statements.query` as a dedicated column instead of overloading `fingerprint`.
- Derive interval average latency from delta total execution time and delta execution count instead of aggregating means.

The existing architecture stays intact: `pg_stat_statements` remains the source of cumulative execution counters, and ClickHouse remains the source of interval analytics. The new log pipeline adds a second source of truth only for statement text history and calling-path attribution.

## Goals

- Guarantee that at least one collection attempt starts within each configured interval slot.
- Preserve full raw logged statements for each observed `query_id`.
- Make interval query output human-usable by exposing normalized statement text.
- Remove mathematically incorrect percentile-of-means style rollups from the interval model.
- Support later analysis of distinct calling paths and path changes during an interval.

## Non-Goals

- Rebuilding the collector around statement logs as the primary execution metric source.
- Computing true latency percentiles from `pg_stat_statements`.
- Introducing concurrent collector runs.
- Discarding raw log lines after a single representative sample is derived.

## Current Problems

### Scheduler Drift

The compose stack runs `bundle exec ruby bin/collector`, then sleeps for the full interval. Any collector runtime adds to the cycle length, so a nominal five-second interval drifts later over time.

### Lossy Sample Query Lookup

`SampleQueryLookup` queries `pg_stat_activity` by `query_id` with `LIMIT 1`. When no matching statement is active, the collector records no sample query and no source metadata, even though the statement may have executed repeatedly during the interval.

### Misleading Interval Metrics

The interval view currently carries forward snapshot `mean_exec_time_ms`. Any downstream rollup that takes percentiles or aggregates of those means is not valid for interval latency analysis.

### Unusable Fingerprint Output

The `fingerprint` field currently mirrors the numeric `queryid`, so interval results expose a machine identifier where operators expect readable SQL.

## Proposed Design

### 1. Fixed-Interval Scheduler

Move scheduling responsibility into the collector runtime instead of the compose shell loop.

Behavior:

- The collector computes scheduled start times from wall clock and a configured interval size.
- Each interval slot triggers at most one collection run.
- Runs are serialized. If one run overruns the next slot, the collector starts the missed slot immediately after the current run finishes.
- The guarantee is start-based: at least one collection attempt begins for each interval boundary.

Implementation shape:

- Replace the external `while true; do ...; sleep N; done` command with a long-lived Ruby scheduler entry point.
- Keep `Collector#run_once` as the unit of collection.
- Add a small scheduler class responsible for interval math, sleeping until the next boundary, and catching up after overruns.

Consequences:

- Collection cadence becomes stable and testable.
- Long runs do not create concurrent writes.
- The collector can emit explicit logs for scheduled time, actual start, finish, and backlog.

### 2. Statement Text in Query Snapshots

Extend the Postgres snapshot query to select `pg_stat_statements.query` and store it as `statement_text` in `query_events`.

Behavior:

- `queryid` remains the stable machine key.
- `statement_text` stores the normalized SQL text provided by `pg_stat_statements`.
- The existing `fingerprint` column should be removed or renamed out of the interval-facing model to avoid semantic confusion.

Recommended schema direction:

- `query_events.queryid`: machine key
- `query_events.statement_text`: normalized SQL text
- No separate `fingerprint` column unless a real fingerprint value distinct from `queryid` is introduced later

If minimizing churn is more important during implementation, `fingerprint` can temporarily remain in storage while views stop exposing it. The end-state schema should use names that match the data.

### 3. Raw Postgres JSON Log Ingestion

Enable structured PostgreSQL logging and ingest the raw log lines into ClickHouse.

Postgres configuration:

- Enable `logging_collector`
- Set `log_destination` to include `jsonlog`
- Use completion-time statement logging so executed statements are emitted after PostgreSQL has computed `query_id`
- Set the local demo configuration to log all completed statements through a duration-based path such as `log_min_duration_statement = 0`
- Use normal Postgres log rotation settings so ingestion can follow rotated files

The PostgreSQL logging docs confirm that `jsonlog` requires `logging_collector`, structured output is designed for import into other systems, and `log_statement` output occurs before a query identifier is calculated. The implementation should not depend on `log_statement` as the primary ingestion source. Source: https://www.postgresql.org/docs/current/runtime-config-logging.html

ClickHouse storage:

- Add a raw log table for imported JSON log rows
- Store at minimum:
  - log timestamp
  - `query_id`
  - SQL statement text
  - database/user/session identifiers when present
  - parsed Rails query-comment metadata such as source location
  - the original raw JSON payload for audit/debug value

Ingestion behavior:

- The collector side tracks imported file positions or imported file segments so rotation does not duplicate or skip lines.
- Ingestion is append-only.
- Empty files, no-op intervals, and rotated files are normal states, not errors.

This raw table is the durable history of what actually ran. It replaces the fragile “grab one active statement if present” behavior.

### 4. Interval Attribution by Joining Logs

Build interval reporting by joining `query_intervals` to raw log rows using `query_id` plus interval time bounds.

Behavior:

- A given interval can reference all raw statements logged for the matching `queryid` between `interval_started_at` and `interval_ended_at`.
- Interval-facing queries can derive:
  - representative source locations
  - distinct source path counts
  - whether calling paths changed during the interval
  - raw statement drill-down for debugging

Important constraint:

- Log correlation is best-effort within the accuracy of PostgreSQL log timestamps and the collector interval boundaries.
- Intervals with no matching logs remain valid intervals. They simply have no statement-history attachment.

This keeps execution metrics and statement history separate, which makes the system easier to reason about and avoids inventing lossy summary columns during collection.

### 5. Correct Interval Latency Metrics

Treat `pg_stat_statements` as cumulative counters and derive interval latency only from deltas.

Interval formulas:

- `delta_exec_time_ms = current.total_exec_time_ms - previous.total_exec_time_ms`
- `delta_exec_count = current.total_exec_count - previous.total_exec_count`
- `avg_exec_time_ms = delta_exec_time_ms / delta_exec_count` when `delta_exec_count > 0`

Behavioral changes:

- Stop using snapshot `mean_exec_time_ms` as an interval metric.
- Remove percentile-of-means or similar rollups from interval-facing queries.
- Keep snapshot `min_exec_time_ms`, `max_exec_time_ms`, `mean_exec_time_ms`, and `stddev_exec_time_ms` only if they are explicitly documented as snapshot values, not interval aggregates.

If interval consumers only need correct interval math, the simplest implementation is to stop exposing the snapshot mean fields from `query_intervals` entirely and expose only derived interval fields.

## Component Changes

### Collector Runtime

- Add a scheduler entry point that repeatedly calls `run_once` on fixed boundaries.
- Extend `Collector::STATS_SQL` to include `query`.
- Populate `statement_text` on inserted query event rows.
- Remove the runtime dependency on `SampleQueryLookup`.

### Postgres Image and Compose

- Configure the local Postgres image for JSON logging with `query_id`.
- Mount or preserve the Postgres log directory so the collector can ingest logs.
- Replace the shell sleep loop in `docker-compose.yml` with the long-lived scheduler process.

### ClickHouse Schema

- Update `query_events` to store `statement_text`.
- Add a raw Postgres log table.
- Update `query_intervals` so interval latency fields are delta-derived and interval-facing output uses `statement_text`.
- Add derived queries or views for interval-to-log correlation as needed.

### Tests

Collector tests:

- Scheduler starts one run per interval boundary without drift.
- Overrun behavior catches up without concurrent execution.
- `statement_text` comes from `pg_stat_statements.query`.

Log ingestion tests:

- JSON log rows ingest into ClickHouse with `query_id` and source metadata.
- Rotation or offset tracking avoids duplicate imports.
- Empty or missing log activity does not fail collection.

ClickHouse integration tests:

- `query_intervals` derives average latency from deltas.
- Interval output exposes human-readable statement text.
- Joined interval/log queries return raw statements for matching windows.

Cross-repo validation:

- Existing smoke and integration checks in `/home/bjw/checkpoint` remain green after schema/query changes.
- Validation should include a path where Rails query comments appear in ingested logs and are visible through interval drill-down.

## Error Handling

- Continue inserting `collector_state` even when no `pg_stat_statements` rows exist.
- Treat missing matching logs as absence of attribution, not as collector failure.
- On malformed JSON log rows, record enough context to diagnose the bad line and continue ingesting the rest of the file when safe.
- On restart, ingestion resumes from tracked file position or the next unprocessed rotated file boundary.

## Risks and Trade-Offs

- Enabling statement logging increases local Postgres log volume. Raw retention is intentional, so ClickHouse storage growth must be expected.
- Correlating by `query_id` and interval timestamps is not equivalent to a perfect per-execution trace. It is still materially better than `pg_stat_activity LIMIT 1`.
- Keeping both snapshot counters and raw logs introduces two data sources, but their responsibilities are cleanly separated.
- Renaming away from `fingerprint` may require coordinated updates in the sibling `checkpoint` repo.

## Open Decisions Resolved

- Scheduler guarantee: start-based
- Attribution source: PostgreSQL structured logs
- Raw statement retention: keep full raw logged statements
- Human-readable query field: separate `statement_text` column, keep `queryid` as machine key

## Implementation Boundary

This design is scoped to the collector repo changes needed for scheduler behavior, schema updates, and log ingestion, plus any coordinated query/test updates required in `/home/bjw/checkpoint` to keep validation working. It does not include broader agent runtime redesign.
