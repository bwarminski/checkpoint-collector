# Checkpoint Collector

This repo owns the collector pipeline, ClickHouse DDLs, local Postgres image,
and the load harness used to generate database traffic.

## Local Run

```bash
docker compose up -d --build
ruby load/harness.rb
```
