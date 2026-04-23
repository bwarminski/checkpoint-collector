# ABOUTME: Documents the missing-index workload and tactical oracle for the load runner MVP.
# ABOUTME: Explains the expected demo app, run command, and oracle verification path.

# Missing Index Todos

This workload drives `GET /todos/status?status=open` against `~/db-specialist-demo` at the same scale as the fixture harness it replaces.

## Defaults

- `rows_per_table: 10_000_000`
- `open_fraction: 0.002`
- `seed: 42`
- `workers: 16`
- `duration_seconds: 60`
- `rate_limit: :unlimited`

## Run

```bash
bin/load run \
  --workload missing-index-todos \
  --adapter adapters/rails/bin/bench-adapter \
  --app-root /home/bjw/db-specialist-demo
```

## Oracle

```bash
ruby workloads/missing_index_todos/oracle.rb runs/<latest> \
  --database-url postgresql://postgres:postgres@localhost:5432/checkpoint_demo \
  --clickhouse-url http://localhost:8123
```

The oracle:

- tree-walks `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` and requires a `Seq Scan` on `todos`
- rejects `Index Scan`, `Index Only Scan`, and `Bitmap Index Scan` on `todos`
- polls ClickHouse by `queryid` fingerprints until total call count reaches `500`

It expects the run record to contain the workload `query_ids` set that identifies the target statement family.
