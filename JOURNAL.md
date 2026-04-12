ABOUTME: Engineering journal for decisions, insights, and reminders.
ABOUTME: Used to preserve context across sessions and tasks.

## 2026-04-09

## 2026-04-12

- Brainstormed and approved a design for collector correctness and schema/query improvements.
- Design direction: fixed-interval start-based scheduler, raw Postgres JSON log ingestion keyed by `query_id`, `query_events.statement_text` sourced from `pg_stat_statements.query`, and interval latency derived from delta total time divided by delta execution count.
- Retain full raw logged statements in ClickHouse for later analysis instead of collapsing to a single representative sample during collection.
- Wrote the implementation plan at `docs/superpowers/plans/2026-04-12-collector-correctness-plan.md`; the plan is cross-repo and updates `checkpoint` before the collector schema reset because removing `fingerprint`, `sample_query`, and snapshot latency columns is a flag-day change.
- Implemented the collector fixed-interval scheduler with wall-clock alignment, serialized runs, skip-ahead after overruns, stderr logging on `run_once` failures, and fresh Postgres/ClickHouse setup per interval from `bin/collector`.
