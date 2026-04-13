# Collector Correctness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the drift-prone collector loop and lossy sample-query capture with a fixed-interval scheduler, log-backed statement attribution, and a corrected ClickHouse interval schema that stays compatible with the sibling `checkpoint` repo after coordinated updates.

**Architecture:** The collector remains the source of `pg_stat_statements` snapshots and `collector_state`, but it becomes a long-lived Ruby process that starts runs on fixed boundaries and opens fresh connections on each pass. PostgreSQL JSON logs become a second append-only input for statement history, stored in ClickHouse and joined to interval data by `queryid` plus `[interval_started_at, interval_ended_at)` bounds. The sibling `checkpoint` repo must switch its queries and validation fixtures from `fingerprint`/`sample_query` and snapshot latency columns to `statement_text`, `avg_exec_time_ms`, and the new raw-log tables before the collector schema reset runs.

**Tech Stack:** Ruby, Minitest, PostgreSQL 16 with JSON logging enabled, ClickHouse 24.3, Docker Compose, TypeScript tests in `/home/bjw/checkpoint`, Python smoke tests in `/home/bjw/checkpoint/tests/smoke`.

---

## File Map

- `/home/bjw/checkpoint-collector/collector/bin/collector`
  Entry point. Replace one-shot connection setup with scheduler startup.
- `/home/bjw/checkpoint-collector/collector/lib/collector.rb`
  Snapshot query and row shaping. Add `statement_text`, remove `fingerprint` and `sample_query`, preserve NULL text.
- `/home/bjw/checkpoint-collector/collector/lib/scheduler.rb`
  New fixed-interval scheduler with skip-ahead semantics and stderr logging on failure.
- `/home/bjw/checkpoint-collector/collector/lib/log_ingester.rb`
  New JSON log reader that resumes from `postgres_log_state`, buffers partial lines, and writes `postgres_logs`.
- `/home/bjw/checkpoint-collector/collector/lib/clickhouse_connection.rb`
  Confirm it can insert the new `postgres_logs` and `postgres_log_state` payloads without hidden assumptions.
- `/home/bjw/checkpoint-collector/collector/db/clickhouse/001_query_events.sql`
  Replace `fingerprint` and `sample_query` with `statement_text Nullable(String)`.
- `/home/bjw/checkpoint-collector/collector/db/clickhouse/003_query_intervals.sql`
  Update the existing interval view definition in place.
- `/home/bjw/checkpoint-collector/collector/db/clickhouse/005_postgres_logs.sql`
  New raw JSON log table using `ReplacingMergeTree`.
- `/home/bjw/checkpoint-collector/collector/db/clickhouse/006_postgres_log_state.sql`
  New ingestion offset state table.
- `/home/bjw/checkpoint-collector/collector/db/clickhouse/004_reset_query_analytics.sql`
  Rebuild all canonical tables and views to match the canonical SQL files above.
- `/home/bjw/checkpoint-collector/collector/test/scheduler_test.rb`
  New scheduler behavior tests.
- `/home/bjw/checkpoint-collector/collector/test/log_ingester_test.rb`
  New ingestion tests.
- `/home/bjw/checkpoint-collector/collector/test/collector_test.rb`
  Update snapshot row expectations.
- `/home/bjw/checkpoint-collector/collector/test/sql/clickhouse_schema_test.rb`
  Update canonical schema assertions.
- `/home/bjw/checkpoint-collector/collector/test/sql/clickhouse_interval_view_test.rb`
  Update live ClickHouse interval behavior assertions.
- `/home/bjw/checkpoint-collector/collector/test/compose_stack_test.rb`
  Extend compose expectations for mounted log directory and long-lived scheduler command if needed.
- `/home/bjw/checkpoint-collector/postgres/Dockerfile`
  Keep PostgreSQL 16, but add config for JSON logging through init files or command args.
- `/home/bjw/checkpoint-collector/postgres/init/`
  Add or update init SQL/config files for logging settings that belong in the image.
- `/home/bjw/checkpoint-collector/docker-compose.yml`
  Replace shell loop, mount log directory into collector, keep health checks valid.
- `/home/bjw/checkpoint/scripts/validate.sh`
  Replace fixture inserts/selects that use removed columns.
- `/home/bjw/checkpoint/extensions/db-specialist.ts`
  Update tool expectations if result fields or table names change.
- `/home/bjw/checkpoint/agent/test/clickhouse_tool.test.ts`
  Update ClickHouse query expectations from `fingerprint`/`sample_query` to `statement_text`/`avg_exec_time_ms`.
- `/home/bjw/checkpoint/tests/smoke/test_clickhouse_schema.py`
  Expect the new raw log tables to exist.

## Task 1: Lock In the New Collector Row Shape

**Files:**
- Modify: `/home/bjw/checkpoint-collector/collector/test/collector_test.rb`
- Modify: `/home/bjw/checkpoint-collector/collector/lib/collector.rb`
- Modify: `/home/bjw/checkpoint-collector/collector/bin/collector`
- Delete: `/home/bjw/checkpoint-collector/collector/lib/sample_query_lookup.rb`
- Delete: `/home/bjw/checkpoint-collector/collector/test/sample_query_lookup_test.rb`

- [ ] **Step 1: Write the failing collector tests**

```ruby
def test_inserts_query_event_rows_with_statement_text_and_no_sample_columns
  stats_connection = StatsConnection.new([
    {
      "queryid" => "42",
      "query" => "SELECT * FROM todos WHERE id = $1",
      "calls" => "7",
      "total_exec_time" => "125.5",
      "rows" => "0"
    }
  ])

  row = Collector.new(
    stats_connection: stats_connection,
    clock: -> { Time.utc(2026, 4, 12, 12, 0, 0) }
  ).run_once.fetch(0)

  assert_equal "SELECT * FROM todos WHERE id = $1", row[:statement_text]
  refute row.key?(:fingerprint)
  refute row.key?(:sample_query)
end

def test_preserves_nil_statement_text_for_internal_queries
  stats_connection = StatsConnection.new([
    {
      "queryid" => "-1",
      "query" => nil,
      "calls" => "1",
      "total_exec_time" => "1.0"
    }
  ])

  row = Collector.new(
    stats_connection: stats_connection,
    clock: -> { Time.utc(2026, 4, 12, 12, 5, 0) }
  ).run_once.fetch(0)

  assert_nil row[:statement_text]
end
```

- [ ] **Step 2: Run the focused collector test file and verify it fails**

Run: `bundle exec ruby collector/test/collector_test.rb`

Expected: failures complaining that `statement_text` is missing and `fingerprint` / `sample_query` are still present.

- [ ] **Step 3: Implement the minimal collector row-shape changes**

```ruby
STATS_SQL = <<~SQL.freeze
  SELECT
    dbid,
    userid,
    toplevel,
    queryid,
    query,
    calls,
    total_exec_time,
    min_exec_time,
    max_exec_time,
    mean_exec_time,
    stddev_exec_time,
    rows,
    shared_blks_hit,
    shared_blks_read,
    local_blks_hit,
    local_blks_read,
    temp_blks_read,
    temp_blks_written
  FROM pg_stat_statements
SQL

def build_row(stats_row, collected_at)
  {
    collected_at: collected_at,
    dbid: stats_row.fetch("dbid", 0).to_i,
    userid: stats_row.fetch("userid", 0).to_i,
    toplevel: toplevel_value(stats_row.fetch("toplevel", nil)),
    queryid: stats_row.fetch("queryid").to_s,
    statement_text: stats_row["query"],
    source_file: nil,
    total_exec_count: stats_row.fetch("calls").to_i,
    total_exec_time_ms: stats_row.fetch("total_exec_time", 0).to_f,
    min_exec_time_ms: stats_row.fetch("min_exec_time", 0).to_f,
    max_exec_time_ms: stats_row.fetch("max_exec_time", 0).to_f,
    mean_exec_time_ms: stats_row.fetch("mean_exec_time", 0).to_f,
    stddev_exec_time_ms: stats_row.fetch("stddev_exec_time", 0).to_f,
    rows_returned_or_affected: stats_row.fetch("rows", 0).to_i,
    shared_blks_hit: stat_value(stats_row, "shared_blks_hit"),
    shared_blks_read: stat_value(stats_row, "shared_blks_read"),
    local_blks_hit: stat_value(stats_row, "local_blks_hit"),
    local_blks_read: stat_value(stats_row, "local_blks_read"),
    temp_blks_read: stat_value(stats_row, "temp_blks_read"),
    temp_blks_written: stat_value(stats_row, "temp_blks_written"),
    total_block_accesses: total_block_accesses(stats_row)
  }
end
```

Also update `collector/bin/collector` so it no longer requires or constructs `SampleQueryLookup`.

- [ ] **Step 4: Remove dead sample-query files**

```bash
git rm collector/lib/sample_query_lookup.rb collector/test/sample_query_lookup_test.rb
```

- [ ] **Step 5: Run the collector tests again**

Run: `bundle exec ruby collector/test/collector_test.rb`

Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add collector/bin/collector collector/lib/collector.rb collector/test/collector_test.rb
git add -u collector/lib/sample_query_lookup.rb collector/test/sample_query_lookup_test.rb
git commit -m "refactor: store statement text in collector snapshots"
```

## Task 2: Add the Fixed-Interval Scheduler

**Files:**
- Create: `/home/bjw/checkpoint-collector/collector/lib/scheduler.rb`
- Create: `/home/bjw/checkpoint-collector/collector/test/scheduler_test.rb`
- Modify: `/home/bjw/checkpoint-collector/collector/bin/collector`
- Modify: `/home/bjw/checkpoint-collector/docker-compose.yml`

- [ ] **Step 1: Write the failing scheduler tests**

```ruby
def test_scheduler_aligns_to_next_future_boundary_after_overrun
  starts = []
  fake_clock = FakeClock.new(
    Time.utc(2026, 4, 12, 12, 0, 0),
    Time.utc(2026, 4, 12, 12, 0, 7),
    Time.utc(2026, 4, 12, 12, 0, 10)
  )

  runner = -> { starts << fake_clock.now }

  Scheduler.new(
    interval_seconds: 5,
    clock: -> { fake_clock.now },
    sleep_until: ->(time) { fake_clock.travel_to(time) },
    stderr: StringIO.new,
    run_once: runner
  ).run_iterations(2)

  assert_equal [
    Time.utc(2026, 4, 12, 12, 0, 0),
    Time.utc(2026, 4, 12, 12, 0, 10)
  ], starts
end

def test_scheduler_logs_and_continues_after_exception
  stderr = StringIO.new
  attempts = 0

  Scheduler.new(
    interval_seconds: 5,
    clock: -> { Time.utc(2026, 4, 12, 12, 0, attempts * 5) },
    sleep_until: ->(*) {},
    stderr: stderr,
    run_once: -> {
      attempts += 1
      raise "boom" if attempts == 1
    }
  ).run_iterations(2)

  assert_includes stderr.string, "boom"
  assert_equal 2, attempts
end
```

- [ ] **Step 2: Run the scheduler test file and verify it fails**

Run: `bundle exec ruby collector/test/scheduler_test.rb`

Expected: FAIL because `Scheduler` does not exist.

- [ ] **Step 3: Implement the scheduler class**

```ruby
class Scheduler
  def initialize(interval_seconds:, clock:, sleep_until:, stderr:, run_once:)
    @interval_seconds = interval_seconds
    @clock = clock
    @sleep_until = sleep_until
    @stderr = stderr
    @run_once = run_once
  end

  def run_forever
    loop { run_slot }
  end

  def run_iterations(count)
    count.times { run_slot }
  end

  private

  def run_slot
    scheduled_at = next_boundary(@clock.call)
    @sleep_until.call(scheduled_at) if @clock.call < scheduled_at

    actual_start = @clock.call
    @run_once.call
  rescue StandardError => error
    @stderr.puts("collector run failed: #{error.message}")
  ensure
    skip_to_next_future_boundary(actual_start || @clock.call)
  end
end
```

Fill in `next_boundary` and `skip_to_next_future_boundary` exactly to implement “skip all missed boundaries, align to next future slot”.

- [ ] **Step 4: Wire the scheduler into the entry point and compose**

```ruby
Scheduler.new(
  interval_seconds: Integer(ENV.fetch("COLLECTOR_INTERVAL_SECONDS", "5")),
  clock: -> { Time.now.utc },
  sleep_until: ->(time) { sleep([time - Time.now.utc, 0].max) },
  stderr: $stderr,
  run_once: lambda {
    stats_connection = PG.connect(ENV.fetch("POSTGRES_URL"))
    clickhouse_connection = ClickhouseConnection.new(base_url: ENV.fetch("CLICKHOUSE_URL"))

    Collector.new(
      stats_connection: stats_connection,
      clickhouse_connection: clickhouse_connection
    ).run_once
  ensure
    stats_connection&.close
  }
).run_forever
```

Update `docker-compose.yml` to run `bundle exec ruby bin/collector` directly, without the outer bash sleep loop.

- [ ] **Step 5: Run the scheduler and compose-related tests**

Run: `bundle exec ruby collector/test/scheduler_test.rb`

Run: `bundle exec ruby collector/test/compose_stack_test.rb`

Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add collector/lib/scheduler.rb collector/test/scheduler_test.rb collector/bin/collector docker-compose.yml
git commit -m "feat: add fixed-interval collector scheduler"
```

## Task 3: Add PostgreSQL JSON Logging and the Log Ingester

**Files:**
- Create: `/home/bjw/checkpoint-collector/collector/lib/log_ingester.rb`
- Create: `/home/bjw/checkpoint-collector/collector/test/log_ingester_test.rb`
- Modify: `/home/bjw/checkpoint-collector/collector/bin/collector`
- Modify: `/home/bjw/checkpoint-collector/postgres/Dockerfile`
- Modify: `/home/bjw/checkpoint-collector/postgres/init/01-extensions.sql`
- Create or Modify: `/home/bjw/checkpoint-collector/postgres/init/03-logging.sql`
- Modify: `/home/bjw/checkpoint-collector/docker-compose.yml`

- [ ] **Step 1: Write the failing log ingester tests**

```ruby
def test_ingests_only_complete_json_lines_with_query_id
  io = StringIO.new(<<~LOG)
    {"timestamp":"2026-04-12 12:00:00.000 UTC","query_id":-7,"statement":"SELECT 1 /*source_location:/app/models/todo.rb:5*/","session_id":"s1","dbname":"checkpoint_demo"}
    {"timestamp":"2026-04-12 12:00:01.000 UTC","message":"checkpoint starting"}
  LOG

  clickhouse = FakeClickHouseConnection.new
  state_store = FakeStateStore.new

  LogIngester.new(
    log_reader: ->(*) { io.read },
    clickhouse_connection: clickhouse,
    state_store: state_store
  ).ingest_file("postgresql.json")

  assert_equal "postgres_logs", clickhouse.table
  assert_equal "-7", clickhouse.rows.fetch(0).fetch(:query_id)
  assert_equal "/app/models/todo.rb:5", clickhouse.rows.fetch(0).fetch(:source_location)
  assert_equal 1, clickhouse.rows.length
end

def test_buffers_partial_trailing_line_until_next_read
  reads = [
    "{\"timestamp\":\"2026-04-12 12:00:00.000 UTC\",\"query_id\":1",
    ",\"statement\":\"SELECT 1\"}\n"
  ]

  clickhouse = FakeClickHouseConnection.new

  ingester = LogIngester.new(
    log_reader: ->(*) { reads.shift.to_s },
    clickhouse_connection: clickhouse,
    state_store: FakeStateStore.new
  )

  ingester.ingest_file("postgresql.json")
  assert_nil clickhouse.table

  ingester.ingest_file("postgresql.json")
  assert_equal 1, clickhouse.rows.length
end
```

- [ ] **Step 2: Run the ingester tests and verify they fail**

Run: `bundle exec ruby collector/test/log_ingester_test.rb`

Expected: FAIL because `LogIngester` does not exist.

- [ ] **Step 3: Implement the ingester with offset tracking and partial-line buffering**

```ruby
class LogIngester
  def initialize(log_reader:, clickhouse_connection:, state_store:, stderr: $stderr)
    @log_reader = log_reader
    @clickhouse_connection = clickhouse_connection
    @state_store = state_store
    @stderr = stderr
    @line_buffers = {}
  end

  def ingest_file(log_file)
    state = @state_store.load(log_file)
    chunk = @log_reader.call(log_file, state.byte_offset)
    payload = @line_buffers.fetch(log_file, "") + chunk.to_s
    lines = payload.split("\n", -1)
    @line_buffers[log_file] = payload.end_with?("\n") ? "" : lines.pop.to_s

    rows = lines.filter_map.with_index do |line, index|
      parse_row(log_file, state.byte_offset, line, index)
    end

    @clickhouse_connection.insert("postgres_logs", rows) unless rows.empty?
    @state_store.save(log_file, state.byte_offset + chunk.bytesize, state.byte_offset + chunk.bytesize)
  end
end
```

`parse_row` must skip lines with no `query_id`, stringify negative IDs, preserve `raw_json`, and parse `source_location` from the SQL comment using the existing `QueryCommentParser`.

- [ ] **Step 4: Configure Postgres JSON logging and mount the log directory**

```yaml
postgres:
  command:
    [
      "postgres",
      "-c", "shared_preload_libraries=pg_stat_statements",
      "-c", "logging_collector=on",
      "-c", "log_destination=jsonlog",
      "-c", "log_min_duration_statement=0",
      "-c", "log_directory=/var/lib/postgresql/data/log"
    ]
  volumes:
    - postgres_logs:/var/lib/postgresql/data/log

collector:
  volumes:
    - postgres_logs:/var/lib/postgresql/data/log:ro
```

Keep PostgreSQL on `postgres:16`; do not downgrade to 14.x because the current image is already 16 and supports `query_id`.

- [ ] **Step 5: Run the ingester tests**

Run: `bundle exec ruby collector/test/log_ingester_test.rb`

Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add collector/lib/log_ingester.rb collector/test/log_ingester_test.rb collector/bin/collector
git add postgres/Dockerfile postgres/init/01-extensions.sql postgres/init/03-logging.sql docker-compose.yml
git commit -m "feat: ingest postgres json logs"
```

## Task 4: Replace the ClickHouse Schema and Interval Math

**Files:**
- Modify: `/home/bjw/checkpoint-collector/collector/db/clickhouse/001_query_events.sql`
- Modify: `/home/bjw/checkpoint-collector/collector/db/clickhouse/003_query_intervals.sql`
- Modify: `/home/bjw/checkpoint-collector/collector/db/clickhouse/004_reset_query_analytics.sql`
- Create: `/home/bjw/checkpoint-collector/collector/db/clickhouse/005_postgres_logs.sql`
- Create: `/home/bjw/checkpoint-collector/collector/db/clickhouse/006_postgres_log_state.sql`
- Modify: `/home/bjw/checkpoint-collector/collector/test/sql/clickhouse_schema_test.rb`
- Modify: `/home/bjw/checkpoint-collector/collector/test/sql/clickhouse_interval_view_test.rb`

- [ ] **Step 1: Write the failing schema and interval tests**

```ruby
def test_query_events_store_statement_text_and_no_fingerprint_columns
  sql = read_sql("001_query_events.sql")

  assert_match(/statement_text\s+Nullable\(String\)/, sql)
  refute_match(/fingerprint\s+String/, sql)
  refute_match(/sample_query\s+Nullable\(String\)/, sql)
end

def test_query_intervals_define_nullable_average_latency
  sql = read_sql("003_query_intervals.sql")

  assert_includes sql, "avg_exec_time_ms"
  assert_includes sql, "IF(delta_exec_count > 0, delta_exec_time_ms / delta_exec_count, NULL)"
  refute_includes sql, "mean_exec_time_ms"
end
```

```ruby
def test_zero_delta_exec_count_emits_null_average_latency
  insert_event(collected_at: "2026-04-10 12:00:00.000", queryid: "q1", statement_text: "SELECT 1", total_exec_count: 10, total_exec_time_ms: 100.0)
  insert_event(collected_at: "2026-04-10 12:05:00.000", queryid: "q1", statement_text: "SELECT 1", total_exec_count: 10, total_exec_time_ms: 100.0)
  insert_matching_state_rows

  row = query_intervals("q1").fetch(0)

  assert_nil row.fetch("avg_exec_time_ms")
end
```

- [ ] **Step 2: Run the SQL test files and verify they fail**

Run: `bundle exec ruby collector/test/sql/clickhouse_schema_test.rb`

Run: `bundle exec ruby collector/test/sql/clickhouse_interval_view_test.rb`

Expected: FAIL because the schema still exposes removed columns and lacks `avg_exec_time_ms`.

- [ ] **Step 3: Implement the new canonical DDL**

```sql
CREATE TABLE query_events (
  collected_at DateTime64(3),
  dbid UInt64,
  userid UInt64,
  toplevel Bool,
  queryid String,
  statement_text Nullable(String),
  source_file Nullable(String),
  total_exec_count UInt64,
  total_exec_time_ms Float64,
  rows_returned_or_affected UInt64,
  shared_blks_hit UInt64,
  shared_blks_read UInt64,
  local_blks_hit UInt64,
  local_blks_read UInt64,
  temp_blks_read UInt64,
  temp_blks_written UInt64,
  total_block_accesses UInt64,
  min_exec_time_ms Float64,
  max_exec_time_ms Float64,
  mean_exec_time_ms Float64,
  stddev_exec_time_ms Float64
) ENGINE = MergeTree
ORDER BY (dbid, userid, toplevel, queryid, collected_at);
```

```sql
CREATE TABLE postgres_logs (
  log_file String,
  byte_offset UInt64,
  log_timestamp DateTime64(3),
  query_id String,
  statement_text Nullable(String),
  database Nullable(String),
  session_id Nullable(String),
  source_location Nullable(String),
  raw_json String
) ENGINE = ReplacingMergeTree
ORDER BY (log_file, byte_offset);
```

```sql
SELECT
  previous_collected_at AS interval_started_at,
  collected_at AS interval_ended_at,
  dateDiff('millisecond', previous_collected_at, collected_at) AS interval_duration_ms,
  dbid,
  userid,
  toplevel,
  queryid,
  statement_text,
  source_file,
  CAST(total_exec_count - previous_total_exec_count AS Int64) AS total_exec_count,
  CAST(total_exec_time_ms - previous_total_exec_time_ms AS Float64) AS delta_exec_time_ms,
  IF(
    CAST(total_exec_count - previous_total_exec_count AS Int64) > 0,
    CAST(total_exec_time_ms - previous_total_exec_time_ms AS Float64)
      / CAST(total_exec_count - previous_total_exec_count AS Int64),
    NULL
  ) AS avg_exec_time_ms
FROM valid_intervals
```

Remove `fingerprint`, `sample_query`, and snapshot min/max/mean/stddev fields from the interval view output. Keep reset guards unchanged.

- [ ] **Step 4: Update the reset SQL to rebuild all canonical objects**

```sql
DROP VIEW IF EXISTS query_intervals;
DROP TABLE IF EXISTS postgres_log_state;
DROP TABLE IF EXISTS postgres_logs;
DROP TABLE IF EXISTS collector_state;
DROP TABLE IF EXISTS query_events;
```

Then inline the full contents of the canonical SQL files so `clickhouse_schema_test.rb` can keep exact-match assertions.

- [ ] **Step 5: Run the schema tests again**

Run: `bundle exec ruby collector/test/sql/clickhouse_schema_test.rb`

Run: `bundle exec ruby collector/test/sql/clickhouse_interval_view_test.rb`

Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add collector/db/clickhouse/001_query_events.sql
git add collector/db/clickhouse/003_query_intervals.sql collector/db/clickhouse/004_reset_query_analytics.sql
git add collector/db/clickhouse/005_postgres_logs.sql collector/db/clickhouse/006_postgres_log_state.sql
git add collector/test/sql/clickhouse_schema_test.rb collector/test/sql/clickhouse_interval_view_test.rb
git commit -m "feat: add log-backed clickhouse query schema"
```

## Task 5: Wire Log Ingestion Into the Collector Loop

**Files:**
- Modify: `/home/bjw/checkpoint-collector/collector/bin/collector`
- Modify: `/home/bjw/checkpoint-collector/collector/lib/collector.rb`
- Modify: `/home/bjw/checkpoint-collector/collector/lib/log_ingester.rb`
- Modify: `/home/bjw/checkpoint-collector/collector/test/compose_stack_test.rb`
- Modify: `/home/bjw/checkpoint-collector/collector/test/clickhouse_connection_test.rb`

- [ ] **Step 1: Write the failing integration-oriented unit tests**

```ruby
def test_scheduler_run_invokes_log_ingestion_before_snapshot_insert
  calls = []

  ingester = -> { calls << :ingest }
  collector = -> { calls << :collect }

  Runner.new(log_ingester: ingester, collector: collector).run_once

  assert_equal [:ingest, :collect], calls
end
```

```ruby
def test_compose_stack_mounts_postgres_logs_read_only_into_collector
  compose = File.read(File.expand_path("../../docker-compose.yml", __dir__))

  assert_includes compose, "/var/lib/postgresql/data/log:ro"
end
```

- [ ] **Step 2: Run the focused tests and verify they fail**

Run: `bundle exec ruby collector/test/compose_stack_test.rb`

Run: `bundle exec ruby collector/test/clickhouse_connection_test.rb`

Expected: FAIL until the runtime orchestration includes the ingester and compose reflects the new mount.

- [ ] **Step 3: Implement orchestration that ingests logs and then snapshots stats with fresh connections**

```ruby
run_once = lambda do
  stats_connection = PG.connect(ENV.fetch("POSTGRES_URL"))
  clickhouse_connection = ClickhouseConnection.new(base_url: ENV.fetch("CLICKHOUSE_URL"))

  LogIngester.new(
    log_reader: FileLogReader.new(log_root: ENV.fetch("POSTGRES_LOG_DIRECTORY")),
    clickhouse_connection: clickhouse_connection,
    state_store: ClickhouseLogState.new(clickhouse_connection: clickhouse_connection)
  ).ingest_pending_files

  Collector.new(
    stats_connection: stats_connection,
    clickhouse_connection: clickhouse_connection
  ).run_once
ensure
  stats_connection&.close
end
```

Keep the ingester and snapshot collector separate objects so the responsibilities remain clear.

- [ ] **Step 4: Run the touched unit tests**

Run: `bundle exec ruby collector/test/compose_stack_test.rb`

Run: `bundle exec ruby collector/test/clickhouse_connection_test.rb`

Run: `bundle exec ruby collector/test/collector_test.rb`

Run: `bundle exec ruby collector/test/log_ingester_test.rb`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add collector/bin/collector collector/lib/collector.rb collector/lib/log_ingester.rb
git add collector/test/compose_stack_test.rb collector/test/clickhouse_connection_test.rb
git commit -m "feat: run log ingestion before stats snapshots"
```

## Task 6: Update the Sibling `checkpoint` Repo for the Breaking Schema Change

**Files:**
- Modify: `/home/bjw/checkpoint/agent/test/clickhouse_tool.test.ts`
- Modify: `/home/bjw/checkpoint/extensions/db-specialist.ts`
- Modify: `/home/bjw/checkpoint/scripts/validate.sh`
- Modify: `/home/bjw/checkpoint/tests/smoke/test_clickhouse_schema.py`
- Search and update any additional live references under `/home/bjw/checkpoint/src`, `/home/bjw/checkpoint/test`, and `/home/bjw/checkpoint/agent/test`

- [ ] **Step 1: Write the failing checkpoint-side tests first**

```ts
test("ClickHouseTool queries findings using statement_text and avg_exec_time_ms", async () => {
  const queries: Array<string> = [];
  const tool = new ClickHouseTool({
    transport: {
      query: async (sql: string) => {
        queries.push(sql);
        return [
          "queryid\tstatement_text\tsource_file\ttotal_exec_count\ttotal_exec_time_ms\tavg_exec_time_ms",
          "101\tSELECT * FROM todos\t/app/controllers/todos_controller.rb:12\t7\t50.5\t7.21",
        ].join("\n");
      },
    },
  });

  const findings = await tool.queryFindings("analyze_db");

  assert.equal(findings[0]?.statement_text, "SELECT * FROM todos");
  assert.match(queries[0] ?? "", /avg_exec_time_ms/);
  assert.doesNotMatch(queries[0] ?? "", /sample_query/);
  assert.doesNotMatch(queries[0] ?? "", /fingerprint/);
});
```

```python
assert "postgres_logs" in tables
assert "postgres_log_state" in tables
```

- [ ] **Step 2: Run the failing checkpoint tests**

Run: `node --import tsx --test /home/bjw/checkpoint/agent/test/clickhouse_tool.test.ts`

Run: `.venv/bin/pytest /home/bjw/checkpoint/tests/smoke/test_clickhouse_schema.py -v`

Expected: FAIL because the current queries and smoke assertions still use the removed columns.

- [ ] **Step 3: Update ClickHouse query generation and validation fixtures**

```ts
return [
  "SELECT",
  "  queryid,",
  "  statement_text,",
  "  source_file,",
  "  sum(total_exec_count) AS total_exec_count,",
  "  sum(delta_exec_time_ms) AS total_exec_time_ms,",
  "  quantile(0.95)(avg_exec_time_ms) AS p95_exec_time_ms",
  "FROM query_intervals",
  "WHERE interval_started_at > now() - INTERVAL 60 MINUTE",
  "GROUP BY queryid, statement_text, source_file",
].join("\n");
```

```bash
run_clickhouse_query "INSERT INTO query_events (collected_at, dbid, userid, toplevel, queryid, statement_text, source_file, total_exec_count, total_exec_time_ms, rows_returned_or_affected, shared_blks_hit, shared_blks_read, local_blks_hit, local_blks_read, temp_blks_read, temp_blks_written, total_block_accesses, min_exec_time_ms, max_exec_time_ms, mean_exec_time_ms, stddev_exec_time_ms) VALUES (...)"
run_clickhouse_query "INSERT INTO postgres_logs (log_file, byte_offset, log_timestamp, query_id, statement_text, database, session_id, source_location, raw_json) VALUES (...)"
```

Use `queryid` as the stable identifier in findings if the agent still needs a machine key; do not repurpose `statement_text` as an identifier.

- [ ] **Step 4: Run the checkpoint tests again**

Run: `node --import tsx --test /home/bjw/checkpoint/agent/test/clickhouse_tool.test.ts`

Run: `.venv/bin/pytest /home/bjw/checkpoint/tests/smoke/test_clickhouse_schema.py -v`

Expected: PASS

- [ ] **Step 5: Commit in the sibling repo**

```bash
cd /home/bjw/checkpoint
git add agent/test/clickhouse_tool.test.ts extensions/db-specialist.ts scripts/validate.sh tests/smoke/test_clickhouse_schema.py
git commit -m "feat: consume collector statement text schema"
```

## Task 7: Run End-to-End Verification Across Both Repos

**Files:**
- No code changes required unless verification exposes a defect

- [ ] **Step 1: Rebuild the local images with the updated collector schema**

Run: `docker build -t checkpoint-postgres:local /home/bjw/checkpoint-collector/postgres`

Run: `docker build -t checkpoint-clickhouse:local /home/bjw/checkpoint-collector`

Expected: both images build successfully.

- [ ] **Step 2: Run the collector repo tests**

Run: `bundle exec ruby collector/test/collector_test.rb`

Run: `bundle exec ruby collector/test/scheduler_test.rb`

Run: `bundle exec ruby collector/test/log_ingester_test.rb`

Run: `bundle exec ruby collector/test/sql/clickhouse_schema_test.rb`

Run: `bundle exec ruby collector/test/sql/clickhouse_interval_view_test.rb`

Expected: PASS

- [ ] **Step 3: Run the checkpoint repo tests that cover the schema contract**

Run: `node --import tsx --test /home/bjw/checkpoint/agent/test/clickhouse_tool.test.ts`

Run: `.venv/bin/pytest /home/bjw/checkpoint/tests/smoke/test_clickhouse_schema.py -v`

Run: `bash /home/bjw/checkpoint/scripts/validate.sh`

Expected: PASS, or clean skip on the live-provider path if credentials are absent.

- [ ] **Step 4: Run docker-compose smoke to confirm the new tables load**

Run: `docker compose up -d --build`

Run: `docker compose exec -T clickhouse clickhouse-client --query "SHOW TABLES"`

Run: `docker compose exec -T clickhouse clickhouse-client --query "SELECT count() FROM postgres_logs"`

Expected: `query_events`, `collector_state`, `query_intervals`, `postgres_logs`, and `postgres_log_state` are present; `postgres_logs` returns a count without error.

- [ ] **Step 5: Commit any verification-driven fixes**

```bash
git status --short
git add collector/bin/collector collector/lib/log_ingester.rb collector/db/clickhouse/003_query_intervals.sql
git commit -m "fix: resolve verification regressions"
```

Only run this step if verification reveals a real defect in one or more of those files. If verification stays green, skip the commit.

## Self-Review Checklist

- Spec coverage:
  - Scheduler skip-ahead semantics: Task 2
  - Fresh per-run connections and catch-and-continue errors: Task 2 and Task 5
  - Remove `fingerprint` / `sample_query`: Task 1 and Task 4
  - JSON log ingestion with offset state and partial-line buffering: Task 3
  - `statement_text` from `pg_stat_statements.query`: Task 1 and Task 4
  - `avg_exec_time_ms` with NULL on zero delta count: Task 4
  - Breaking updates in `~/checkpoint`: Task 6
  - Cross-repo verification: Task 7
- Placeholder scan:
  - No `TODO`, `TBD`, or “similar to Task N” placeholders should remain.
- Type consistency:
  - Use `queryid` / `query_id` as the stable key everywhere.
  - Use `statement_text` for human-readable SQL everywhere.
  - Use `avg_exec_time_ms` as nullable interval latency everywhere.
