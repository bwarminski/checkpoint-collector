ABOUTME: Engineering journal for decisions, insights, and reminders.
ABOUTME: Used to preserve context across sessions and tasks.

## 2026-04-09

## 2026-04-12

- Brainstormed and approved a design for collector correctness and schema/query improvements.
- Design direction: fixed-interval start-based scheduler, raw Postgres JSON log ingestion keyed by `query_id`, `query_events.statement_text` sourced from `pg_stat_statements.query`, and interval latency derived from delta total time divided by delta execution count.
- Retain full raw logged statements in ClickHouse for later analysis instead of collapsing to a single representative sample during collection.
- Wrote the implementation plan at `docs/superpowers/plans/2026-04-12-collector-correctness-plan.md`; the plan is cross-repo and updates `checkpoint` before the collector schema reset because removing `fingerprint`, `sample_query`, and snapshot latency columns is a flag-day change.
- Updated the collector ClickHouse schema to replace `fingerprint` and `sample_query` with `statement_text`, added `postgres_logs` and `postgres_log_state`, and changed `query_intervals` to expose delta-derived `avg_exec_time_ms`.
- `collector/test/sql/clickhouse_schema_test.rb` passes after the schema changes. `collector/test/sql/clickhouse_interval_view_test.rb` still skips in this shell because `CLICKHOUSE_URL` is not reachable over HTTP, even with an existing healthy ClickHouse container present.
