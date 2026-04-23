# Checkpoint Collector

This repo owns the collector pipeline, ClickHouse DDLs, the local Postgres and
ClickHouse stack, and the load runner used to generate benchmark traffic
against external apps.

## Local Run

```bash
docker compose up -d --build
make load-smoke
```

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
