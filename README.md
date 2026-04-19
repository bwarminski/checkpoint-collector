# Checkpoint Collector

This repo owns the collector pipeline, ClickHouse DDLs, local Postgres image,
and the load harness used to generate database traffic.

## Local Run

```bash
docker compose up -d --build
ruby load/harness.rb
```

## Fixture Harness

Use `bin/fixture missing-index all` to reproduce the missing-index pathology
against an externally started `db-specialist-demo` app. Oracle tag details and
the add-index verification flow live in `fixtures/missing-index/README.md`.
