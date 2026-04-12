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
- Runs are serialized. If one run overruns one or more slot boundaries, the collector skips all missed boundaries and aligns to the next future slot. It does not run catch-up passes for missed slots, since back-to-back runs would produce near-zero-duration intervals.
- The guarantee is start-based: at least one collection attempt begins for each interval boundary that falls outside an active run window.

Implementation shape:

- Replace the external `while true; do ...; sleep N; done` command with a long-lived Ruby scheduler entry point.
- Keep `Collector#run_once` as the unit of collection.
- Add a small scheduler class responsible for interval math, sleeping until the next boundary, and skipping missed slots.
- Connection lifecycle: the collector establishes fresh Postgres and ClickHouse connections on each `run_once` call, rather than holding persistent connections across interval boundaries. This avoids stale connection problems in a long-lived process without adding reconnect logic.
- The scheduler guarantee wording: "at least one collection attempt begins for each interval boundary that does not fall within an active run window." Slots fully inside an overrun window are skipped.

Exception handling:

- If `run_once` raises an exception, the scheduler catches it, logs it to stderr, and continues to the next interval slot. A transient Postgres connection drop should not kill the long-lived process.

Consequences:

- Collection cadence becomes stable and testable.
- Long runs do not create concurrent writes.
- The collector can emit explicit logs for scheduled time, actual start, finish, and any skipped slots.

### 2. Statement Text in Query Snapshots

Extend the Postgres snapshot query to select `pg_stat_statements.query` and store it as `statement_text` in `query_events`.

Behavior:

- `queryid` remains the stable machine key.
- `statement_text` stores the normalized SQL text provided by `pg_stat_statements`.
- The existing `fingerprint` column should be removed or renamed out of the interval-facing model to avoid semantic confusion.

Recommended schema direction:

- `query_events.queryid`: machine key (String, signed decimal representation of the pg_stat_statements bigint)
- `query_events.statement_text`: normalized SQL text, `Nullable(String)` — NULL when `pg_stat_statements.query` is NULL (can occur for internal Postgres queries)
- The `fingerprint` column is removed from `query_events`. The `sample_query` column is also removed.
- `query_intervals` view stops exposing `fingerprint` and `sample_query`, exposes `statement_text` instead.

Cross-repo note: removing `fingerprint` and `sample_query` requires coordinated updates in the sibling `checkpoint` repo. Verify no checkpoint tests or queries reference these columns before deploying.

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
  - `query_id` (String, signed decimal — must match the `queryid` representation used in `query_events`)
  - SQL statement text
  - database/user/session identifiers when present
  - parsed Rails query-comment metadata such as source location
  - the original raw JSON payload for audit/debug value

Note: Postgres jsonlog emits `query_id` as a signed 64-bit integer. The ingester must stringify it using signed decimal representation to match the `queryid` String values in `query_events`. Negative values are valid.

Requires PostgreSQL 14+ (earlier versions do not emit `query_id` in the jsonlog format). The compose stack must pin the Postgres image to 14.x or a specific tested version.

Ingestion behavior:

- The collector tracks imported file positions in a ClickHouse table `postgres_log_state` with columns `log_file String, byte_offset UInt64, file_size_at_last_read UInt64, collected_at DateTime64`. This state survives collector restarts without requiring a separate Docker volume.
- On resume: if the current file size is smaller than `byte_offset` in the tracked state, treat the file as rotated and start from offset 0. Otherwise resume from `byte_offset`.
- Duplicate ingestion on crash-restart: ClickHouse log rows and offset updates are not atomic. On crash between ingesting rows and writing the updated offset, the same bytes may be re-ingested. The `postgres_logs` table should use a `ReplacingMergeTree` engine (keyed on `log_file, byte_offset`) or downstream queries should DISTINCT on `(log_timestamp, query_id)` to suppress visible duplicates.
- Partial trailing lines: when reading a log file that Postgres is actively writing, the last line may be incomplete. The ingester should buffer incomplete lines (no trailing newline) across read cycles rather than treating them as malformed JSON. Only lines with valid complete JSON are ingested; permanently unparseable lines (not just truncated) are skipped with an error log.
- Log lines missing a `query_id` field (e.g., connection events, checkpoints) are skipped without error.
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

Important constraints:

- Log correlation is best-effort within the accuracy of PostgreSQL log timestamps and the collector interval boundaries. Join bounds use `[interval_started_at, interval_ended_at)` — inclusive start, exclusive end — to avoid double-attaching log lines at a boundary between two adjacent intervals.
- Intervals with no matching logs remain valid intervals. They simply have no statement-history attachment.
- A single `query_id` may appear in logs from multiple sessions and call sites within the same interval window. "Representative source location" is defined as the most frequent `source_location` value among matched log rows for that interval, not an arbitrary first-match. This is documented as a heuristic, not a precise attribution.

This keeps execution metrics and statement history separate, which makes the system easier to reason about and avoids inventing lossy summary columns during collection.

### 5. Correct Interval Latency Metrics

Treat `pg_stat_statements` as cumulative counters and derive interval latency only from deltas.

Interval formulas:

- `delta_exec_time_ms = current.total_exec_time_ms - previous.total_exec_time_ms`
- `delta_exec_count = current.total_exec_count - previous.total_exec_count`
- `avg_exec_time_ms = delta_exec_time_ms / delta_exec_count` when `delta_exec_count > 0`, otherwise NULL

ClickHouse SQL: use `IF(delta_exec_count > 0, delta_exec_time_ms / delta_exec_count, NULL)`. The column type must be `Nullable(Float64)`. Do not use bare division — ClickHouse integer division by zero returns 0, not NULL, which silently produces wrong latency values for zero-execution intervals.

Behavioral changes:

- Stop using snapshot `mean_exec_time_ms` as an interval metric.
- Remove percentile-of-means or similar rollups from interval-facing queries.
- Remove `min_exec_time_ms`, `max_exec_time_ms`, `mean_exec_time_ms`, and `stddev_exec_time_ms` from `query_intervals` entirely. These are snapshot values with no valid interval interpretation. Keeping them in an interval-facing view will cause misuse. Consumers that need snapshot stats can join directly to `query_events`.

`query_intervals` exposes only delta-derived fields: `total_exec_count` (delta), `delta_exec_time_ms`, `avg_exec_time_ms` (Nullable, IF-guarded), and delta block/row counters.

## Component Changes

### Collector Runtime

- Add a scheduler entry point that repeatedly calls `run_once` on fixed boundaries. Exceptions from `run_once` are caught and logged; the scheduler continues to the next slot.
- Extend `Collector::STATS_SQL` to include `query`.
- Populate `statement_text` (Nullable) on inserted query event rows from `pg_stat_statements.query`. Preserve NULL — do not coerce to empty string.
- Remove the runtime dependency on `SampleQueryLookup`. Remove `sample_query_lookup.rb`.
- Remove `fingerprint` and `sample_query` from all inserted rows.

### Postgres Image and Compose

- Requires PostgreSQL 14+. Pin the Postgres image to 14.x or higher.
- Configure the local Postgres image for JSON logging with `query_id` (enable `logging_collector`, set `log_destination` to include `jsonlog`, set `log_min_duration_statement = 0`).
- Mount the Postgres log directory into the collector container so the ingester can read log files.
- Replace the shell sleep loop in `docker-compose.yml` with the long-lived scheduler process.

### ClickHouse Schema

- Update `query_events`: add `statement_text Nullable(String)`, remove `fingerprint`, remove `sample_query`. Update `004_reset_query_analytics.sql` to match.
- Add a raw Postgres log table `postgres_logs` using `ReplacingMergeTree` engine keyed on `(log_file, byte_offset)` to suppress duplicates from crash-restart re-ingestion. Columns: `log_file String, byte_offset UInt64, log_timestamp DateTime64, query_id String, statement_text Nullable(String), database Nullable(String), session_id Nullable(String), source_location Nullable(String), raw_json String`.
- Add a log position tracking table `postgres_log_state`: `log_file String, byte_offset UInt64, file_size_at_last_read UInt64, collected_at DateTime64`.
- Update `query_intervals`: remove `fingerprint`, `sample_query`, `min_exec_time_ms`, `max_exec_time_ms`, `mean_exec_time_ms`, `stddev_exec_time_ms` from SELECT. Add `statement_text`. Add `avg_exec_time_ms Nullable(Float64)` computed with `IF(delta_exec_count > 0, delta_exec_time_ms / delta_exec_count, NULL)` guard.
- Add derived queries or views for interval-to-log correlation as needed.

### Tests

Scheduler tests (`test/scheduler_test.rb`):

- Scheduler starts one run per interval boundary without drift (verifies next boundary is calculated from wall clock, not from run completion time).
- Single-slot overrun: run that exceeds the next boundary still starts the following boundary at the correct future time, not immediately.
- Multiple missed slots: after a run that spans two boundaries, the scheduler aligns to the next future boundary — no catch-up runs for missed slots.
- Exception in `run_once`: scheduler catches the exception, logs it to stderr, and proceeds to the next interval without crashing.

Collector unit tests (`test/collector_test.rb`):

- `statement_text` is populated from `pg_stat_statements.query` when present.
- `statement_text` is nil (not empty string) when `pg_stat_statements.query` is nil.
- Rows do not contain `fingerprint` or `sample_query` keys.

Log ingestion tests (`test/log_ingester_test.rb`):

- JSON log line with `query_id` and statement text ingests into ClickHouse with correct field mapping.
- `query_id` from log JSON (numeric) is stringified as signed decimal to match `query_events.queryid` representation.
- Log line missing `query_id` field (e.g., connection event, checkpoint) is skipped without error.
- Rotation/offset tracking: ingester resumes from the last recorded byte offset in `postgres_log_state`, does not re-ingest prior rows.
- Empty log file does not fail collection.
- Malformed JSON line is skipped; ingestion continues with remaining lines.
- Partial trailing line (no newline at end, file still being written): buffered across read cycles, not treated as malformed.

ClickHouse integration tests (`test/sql/clickhouse_interval_view_test.rb` — extend existing):

- `query_intervals` derives `avg_exec_time_ms` correctly from deltas when `delta_exec_count > 0`.
- `query_intervals` returns NULL (not 0) for `avg_exec_time_ms` when `delta_exec_count` is 0.
- Interval output exposes `statement_text` (not `fingerprint` or `sample_query`).
- `query_intervals` does not expose `mean_exec_time_ms` as an interval aggregate (or documents it as a snapshot column).

Schema tests (`test/sql/clickhouse_schema_test.rb` — update existing):

- `query_events` has `statement_text Nullable(String)`, no `fingerprint`, no `sample_query`.
- `postgres_logs` table exists with `query_id`, `statement_text`, `raw_json` columns.
- `postgres_log_state` table exists with `log_file`, `byte_offset` columns.
- Reset SQL rebuilds all new tables and views correctly.

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
- Scheduler overrun policy: skip all missed boundaries, align to next future slot
- Scheduler exception policy: catch and continue, log to stderr
- Attribution source: PostgreSQL structured logs
- Raw statement retention: keep full raw logged statements
- Human-readable query field: separate `statement_text` column (Nullable), keep `queryid` as machine key
- Remove `fingerprint` and `sample_query` columns entirely (not just stop exposing)
- Log position state storage: ClickHouse table (`postgres_log_state`)
- avg_exec_time_ms when delta_exec_count = 0: return NULL via IF guard (not 0)
- Remove snapshot min/max/mean/stddev from query_intervals (not just "document as snapshot")
- Connection lifecycle: fresh connections per run_once, not persistent across scheduler iterations
- Rotation identity: filename + file_size_at_last_read heuristic (truncation = rotation)
- Write atomicity: accept duplicate risk, suppress via ReplacingMergeTree on postgres_logs
- Interval join bounds: [start, end) inclusive-start exclusive-end
- Deployment ordering: checkpoint repo first, then collector schema

## Deployment Checklist

Schema removals (`fingerprint`, `sample_query`, snapshot stats columns) are breaking changes for any running queries or tests in the sibling `checkpoint` repo. Deployment order:

1. Update `checkpoint` repo: remove all references to `fingerprint`, `sample_query`, `min_exec_time_ms`, `max_exec_time_ms`, `mean_exec_time_ms`, `stddev_exec_time_ms` from queries and tests.
2. Deploy collector schema changes (updated `query_events`, `query_intervals`, new log tables).
3. Run cross-repo integration tests to verify no regressions.

This is a flag-day deployment. Both repos must be updated before the schema migration runs.

## Implementation Boundary

This design is scoped to the collector repo changes needed for scheduler behavior, schema updates, and log ingestion, plus any coordinated query/test updates required in `/home/bjw/checkpoint` to keep validation working. It does not include broader agent runtime redesign.
