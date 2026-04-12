ABOUTME: Engineering journal for decisions, insights, and reminders.
ABOUTME: Used to preserve context across sessions and tasks.

## 2026-04-09

## 2026-04-12

- Brainstormed and approved a design for collector correctness and schema/query improvements.
- Design direction: fixed-interval start-based scheduler, raw Postgres JSON log ingestion keyed by `query_id`, `query_events.statement_text` sourced from `pg_stat_statements.query`, and interval latency derived from delta total time divided by delta execution count.
- Retain full raw logged statements in ClickHouse for later analysis instead of collapsing to a single representative sample during collection.
- Wrote the implementation plan at `docs/superpowers/plans/2026-04-12-collector-correctness-plan.md`; the plan is cross-repo and updates `checkpoint` before the collector schema reset because removing `fingerprint`, `sample_query`, and snapshot latency columns is a flag-day change.
- Cross-repo verification passed for collector unit/schema tests plus the checkpoint worktree contract tests after renaming checkpoint findings from `fingerprint` to `queryid` and joining `postgres_logs` for source attribution. The checkpoint worktree commits are `6313c2d` (`feat: rename checkpoint findings to queryid`) and `d8b8171` (`test: make clickhouse smoke stack-safe`).
- Literal compose smoke with published ports cannot run concurrently with the already-running `checkpoint` stack because `5432` and `8123` are occupied. Verified the ClickHouse schema load with a direct image smoke instead, and hardened `checkpoint/tests/smoke/test_clickhouse_schema.py` to avoid host-port collisions by using `docker run`/`docker exec` against the built image.
- Updated the collector-correctness design to replace `source_file` / `source_location` as first-class schema columns with a generic `comment_metadata Map(String, String)` on snapshots and raw logs. Raw `postgres_logs` remain the authoritative source when one `queryid` has multiple metadata variants in the same interval.
