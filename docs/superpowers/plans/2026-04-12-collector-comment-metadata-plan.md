# Collector Comment Metadata Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `source_file` / `source_location` as first-class schema columns with generic `comment_metadata Map(String, String)` across collector snapshots, raw logs, and interval-facing queries.

**Architecture:** This is a focused follow-on plan that supersedes only the metadata-related parts of `docs/superpowers/plans/2026-04-12-collector-correctness-plan.md`. The collector and log ingester will share one parser that extracts all SQL comment key/value pairs into a Ruby hash, which ClickHouse stores as `Map(String, String)`. Snapshot tables may still carry only one representative metadata map per `queryid`, while `postgres_logs` remains the authoritative source for all metadata variants seen during an interval.

**Tech Stack:** Ruby, Minitest, ClickHouse 24.3, PostgreSQL 16 jsonlog, TypeScript tests in `/home/bjw/checkpoint/.worktrees/collector-correctness-checkpoint`.

---

## Scope

This plan covers only the metadata generalization:

- replace `source_file` in `query_events` / `query_intervals`
- replace `source_location` in `postgres_logs`
- generalize `QueryCommentParser`
- update collector/log-ingester tests and ClickHouse schema tests
- update the sibling `checkpoint` repo queries/tests to read `comment_metadata`

It does **not** revisit the already-completed scheduler, offset tracking, or raw log ingestion work except where those components need schema-compatible edits.

## File Map

- `/home/bjw/checkpoint-collector/collector/lib/query_comment_parser.rb`
  Generalize from `source_location` extraction to full key/value extraction.
- `/home/bjw/checkpoint-collector/collector/test/query_comment_parser_test.rb`
  Lock in parser behavior, including duplicate keys and mixed separator styles.
- `/home/bjw/checkpoint-collector/collector/lib/collector.rb`
  Replace `source_file` on snapshot rows with `comment_metadata`.
- `/home/bjw/checkpoint-collector/collector/lib/log_ingester.rb`
  Replace `source_location` on raw log rows with `comment_metadata`.
- `/home/bjw/checkpoint-collector/collector/test/collector_test.rb`
  Update row-shape expectations for snapshot inserts.
- `/home/bjw/checkpoint-collector/collector/test/log_ingester_test.rb`
  Update raw log row expectations for metadata maps.
- `/home/bjw/checkpoint-collector/collector/db/clickhouse/001_query_events.sql`
  Remove `source_file`; add `comment_metadata Map(String, String)`.
- `/home/bjw/checkpoint-collector/collector/db/clickhouse/003_query_intervals.sql`
  Remove `source_file`; carry `comment_metadata`.
- `/home/bjw/checkpoint-collector/collector/db/clickhouse/004_reset_query_analytics.sql`
  Keep canonical reset SQL aligned with the current schema.
- `/home/bjw/checkpoint-collector/collector/db/clickhouse/005_postgres_logs.sql`
  Remove `source_location`; add `comment_metadata Map(String, String)`.
- `/home/bjw/checkpoint-collector/collector/test/sql/clickhouse_schema_test.rb`
  Update DDL assertions.
- `/home/bjw/checkpoint-collector/collector/test/sql/clickhouse_interval_view_test.rb`
  Update interval-view fixture inserts and assertions.
- `/home/bjw/checkpoint-collector/collector/test/runtime_orchestration_test.rb`
  Update fake snapshot/log rows if they assert exact inserted payloads.
- `/home/bjw/checkpoint/.worktrees/collector-correctness-checkpoint/extensions/db-specialist.ts`
  Replace direct source columns with metadata map access in ClickHouse queries.
- `/home/bjw/checkpoint/.worktrees/collector-correctness-checkpoint/test/tools/clickhouse_tool.test.ts`
  Update result-shape assertions.
- `/home/bjw/checkpoint/.worktrees/collector-correctness-checkpoint/agent/test/clickhouse_tool.test.ts`
  Update agent-side ClickHouse expectations.
- `/home/bjw/checkpoint/.worktrees/collector-correctness-checkpoint/tests/smoke/test_clickhouse_schema.py`
  Assert `comment_metadata` exists and `source_*` columns do not.

## Task 1: Generalize Query Comment Parsing

**Files:**
- Modify: `/home/bjw/checkpoint-collector/collector/test/query_comment_parser_test.rb`
- Modify: `/home/bjw/checkpoint-collector/collector/lib/query_comment_parser.rb`

- [ ] **Step 1: Write the failing parser tests**

```ruby
def test_parses_all_key_value_pairs_from_comment_blocks
  comment = "/*application:demo,controller:todos,action:index,source_location:/app/controllers/todos_controller.rb:12*/"

  parsed = QueryCommentParser.parse_from_query("SELECT 1 #{comment}")

  assert_equal(
    {
      "application" => "demo",
      "controller" => "todos",
      "action" => "index",
      "source_location" => "/app/controllers/todos_controller.rb:12"
    },
    parsed
  )
end

def test_last_duplicate_key_wins
  parsed = QueryCommentParser.parse_from_query(
    "SELECT 1 /*controller:todos*/ /*controller:archived_todos,action:index*/"
  )

  assert_equal(
    {
      "controller" => "archived_todos",
      "action" => "index"
    },
    parsed
  )
end

def test_returns_empty_hash_when_no_metadata_is_present
  assert_equal({}, QueryCommentParser.parse_from_query("SELECT 1"))
end
```

- [ ] **Step 2: Run the parser test file and verify it fails**

Run: `bundle exec ruby test/query_comment_parser_test.rb`

Expected: FAIL because the parser currently returns `{:source_file=>...}` instead of a metadata hash.

- [ ] **Step 3: Implement the minimal parser change**

```ruby
class QueryCommentParser
  COMMENT_PATTERN = %r{/\*(.*?)\*/}m.freeze
  PAIR_PATTERN = /([A-Za-z0-9_]+)\s*[:=]\s*([^,]+)$/.freeze

  def self.parse_from_query(query_text)
    return {} if query_text.nil?

    query_text.scan(COMMENT_PATTERN).each_with_object({}) do |(body), pairs|
      body.split(",").each do |part|
        token = part.to_s.strip
        next if token.empty?

        match = token.match(/\A([A-Za-z0-9_]+)\s*[:=]\s*(.+)\z/)
        next unless match

        pairs[match[1]] = match[2].strip
      end
    end
  end
end
```

- [ ] **Step 4: Run the parser tests again**

Run: `bundle exec ruby test/query_comment_parser_test.rb`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add collector/lib/query_comment_parser.rb collector/test/query_comment_parser_test.rb
git commit -m "refactor: generalize query comment parsing"
```

## Task 2: Replace Snapshot and Raw Log Source Columns with `comment_metadata`

**Files:**
- Modify: `/home/bjw/checkpoint-collector/collector/test/collector_test.rb`
- Modify: `/home/bjw/checkpoint-collector/collector/lib/collector.rb`
- Modify: `/home/bjw/checkpoint-collector/collector/test/log_ingester_test.rb`
- Modify: `/home/bjw/checkpoint-collector/collector/lib/log_ingester.rb`
- Modify: `/home/bjw/checkpoint-collector/collector/test/runtime_orchestration_test.rb`

- [ ] **Step 1: Write the failing collector/log-ingester tests**

```ruby
def test_collector_inserts_comment_metadata_hash
  stats_connection = StatsConnection.new([
    {
      "queryid" => "42",
      "query" => "SELECT * FROM todos /*application:demo,controller:todos,action:index*/",
      "calls" => "1",
      "total_exec_time" => "1.0"
    }
  ])

  row = Collector.new(
    stats_connection: stats_connection,
    clickhouse_connection: FakeClickhouseConnection.new,
    clock: -> { Time.utc(2026, 4, 12, 12, 0, 0) }
  ).send(:build_row, stats_connection.rows.first, Time.utc(2026, 4, 12, 12, 0, 0))

  assert_equal(
    { "application" => "demo", "controller" => "todos", "action" => "index" },
    row[:comment_metadata]
  )
  refute row.key?(:source_file)
end

def test_log_ingester_inserts_comment_metadata_hash
  log_line = "{\"timestamp\":\"2026-04-12 12:00:00.000 UTC\",\"query_id\":7,\"statement\":\"SELECT 1 /*controller:todos,action:index*/\",\"session_id\":\"s1\",\"dbname\":\"checkpoint_demo\"}\n"
  clickhouse = FakeClickhouseConnection.new

  LogIngester.new(
    log_reader: ->(*) { log_line },
    clickhouse_connection: clickhouse,
    state_store: FakeStateStore.new
  ).ingest_file("postgresql.json")

  row = clickhouse.rows.fetch(0)

  assert_equal({ "controller" => "todos", "action" => "index" }, row[:comment_metadata])
  refute row.key?(:source_location)
end
```

- [ ] **Step 2: Run the focused tests and verify they fail**

Run: `bundle exec ruby test/collector_test.rb`

Expected: FAIL because rows still expose `source_file`.

Run: `bundle exec ruby test/log_ingester_test.rb`

Expected: FAIL because rows still expose `source_location`.

- [ ] **Step 3: Implement the minimal row-shape changes**

```ruby
parsed = QueryCommentParser.parse_from_query(stats_row["query"])

{
  collected_at: collected_at,
  dbid: stats_row.fetch("dbid", 0).to_i,
  userid: stats_row.fetch("userid", 0).to_i,
  toplevel: toplevel_value(stats_row.fetch("toplevel", nil)),
  queryid: stats_row.fetch("queryid").to_s,
  statement_text: stats_row["query"],
  comment_metadata: parsed,
  total_exec_count: stats_row.fetch("calls").to_i,
  total_exec_time_ms: stats_row.fetch("total_exec_time", 0).to_f,
  ...
}
```

```ruby
parsed = QueryCommentParser.parse_from_query(statement_text)

{
  log_file: log_file,
  byte_offset: byte_offset,
  log_timestamp: Time.parse(payload.fetch("timestamp")).utc,
  query_id: query_id.to_s,
  statement_text: statement_text,
  database: payload["dbname"],
  session_id: payload["session_id"],
  comment_metadata: parsed,
  raw_json: raw_json
}
```

Update runtime-orchestration test fixtures anywhere they assert exact inserted row payloads.

- [ ] **Step 4: Run the focused tests again**

Run: `bundle exec ruby test/collector_test.rb`

Expected: PASS

Run: `bundle exec ruby test/log_ingester_test.rb`

Expected: PASS

Run: `bundle exec ruby test/runtime_orchestration_test.rb`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add collector/lib/collector.rb collector/test/collector_test.rb
git add collector/lib/log_ingester.rb collector/test/log_ingester_test.rb
git add collector/test/runtime_orchestration_test.rb
git commit -m "refactor: store query comment metadata maps"
```

## Task 3: Align ClickHouse Schema and Interval View

**Files:**
- Modify: `/home/bjw/checkpoint-collector/collector/db/clickhouse/001_query_events.sql`
- Modify: `/home/bjw/checkpoint-collector/collector/db/clickhouse/003_query_intervals.sql`
- Modify: `/home/bjw/checkpoint-collector/collector/db/clickhouse/004_reset_query_analytics.sql`
- Modify: `/home/bjw/checkpoint-collector/collector/db/clickhouse/005_postgres_logs.sql`
- Modify: `/home/bjw/checkpoint-collector/collector/test/sql/clickhouse_schema_test.rb`
- Modify: `/home/bjw/checkpoint-collector/collector/test/sql/clickhouse_interval_view_test.rb`

- [ ] **Step 1: Write the failing schema/view tests**

```ruby
def test_query_events_schema_uses_comment_metadata_map
  sql = read_sql("001_query_events.sql")

  assert_match(/comment_metadata\s+Map\(String, String\)/, sql)
  refute_match(/source_file\s+Nullable\(String\)/, sql)
end

def test_postgres_logs_schema_uses_comment_metadata_map
  sql = read_sql("005_postgres_logs.sql")

  assert_match(/comment_metadata\s+Map\(String, String\)/, sql)
  refute_match(/source_location\s+Nullable\(String\)/, sql)
end

def test_query_intervals_exposes_comment_metadata_not_source_file
  rows = query_intervals("q1")

  assert_equal({ "controller" => "todos" }, rows.fetch(0).fetch("comment_metadata"))
  refute rows.fetch(0).key?("source_file")
end
```

- [ ] **Step 2: Run the schema and interval-view tests and verify they fail**

Run: `bundle exec ruby test/sql/clickhouse_schema_test.rb`

Expected: FAIL because the canonical SQL still references `source_file` / `source_location`.

Run: `bundle exec ruby test/sql/clickhouse_interval_view_test.rb`

Expected: FAIL because fixture inserts and view output still expect `source_file`.

- [ ] **Step 3: Implement the DDL and view changes**

```sql
CREATE TABLE query_events (
  collected_at DateTime64(3),
  dbid UInt64,
  userid UInt64,
  toplevel Bool,
  queryid String,
  statement_text Nullable(String),
  comment_metadata Map(String, String),
  total_exec_count UInt64,
  total_exec_time_ms Float64,
  ...
)
```

```sql
CREATE TABLE IF NOT EXISTS postgres_logs (
  log_file String,
  byte_offset UInt64,
  log_timestamp DateTime64(3),
  query_id String,
  statement_text Nullable(String),
  database Nullable(String),
  session_id Nullable(String),
  comment_metadata Map(String, String),
  raw_json String
) ENGINE = ReplacingMergeTree
ORDER BY (log_file, byte_offset);
```

```sql
SELECT
  previous_collected_at AS interval_started_at,
  collected_at AS interval_ended_at,
  ...,
  queryid,
  statement_text,
  comment_metadata,
  delta_exec_count AS total_exec_count,
  delta_exec_time_ms,
  IF(delta_exec_count > 0, delta_exec_time_ms / delta_exec_count, NULL) AS avg_exec_time_ms
FROM valid_intervals;
```

Update `004_reset_query_analytics.sql` to match the canonical files exactly.

- [ ] **Step 4: Run the schema and interval-view tests again**

Run: `bundle exec ruby test/sql/clickhouse_schema_test.rb`

Expected: PASS

Run: `bundle exec ruby test/sql/clickhouse_interval_view_test.rb`

Expected: PASS or the existing environment-based skip for live ClickHouse access.

- [ ] **Step 5: Commit**

```bash
git add collector/db/clickhouse/001_query_events.sql
git add collector/db/clickhouse/003_query_intervals.sql
git add collector/db/clickhouse/004_reset_query_analytics.sql
git add collector/db/clickhouse/005_postgres_logs.sql
git add collector/test/sql/clickhouse_schema_test.rb
git add collector/test/sql/clickhouse_interval_view_test.rb
git commit -m "feat: generalize collector metadata schema"
```

## Task 4: Update `checkpoint` Consumer Queries to Read `comment_metadata`

**Files:**
- Modify: `/home/bjw/checkpoint/.worktrees/collector-correctness-checkpoint/extensions/db-specialist.ts`
- Modify: `/home/bjw/checkpoint/.worktrees/collector-correctness-checkpoint/test/tools/clickhouse_tool.test.ts`
- Modify: `/home/bjw/checkpoint/.worktrees/collector-correctness-checkpoint/agent/test/clickhouse_tool.test.ts`
- Modify: `/home/bjw/checkpoint/.worktrees/collector-correctness-checkpoint/tests/smoke/test_clickhouse_schema.py`

- [ ] **Step 1: Write the failing checkpoint-side tests**

```typescript
test('clickhouse tool reads comment metadata instead of source columns', async () => {
  const rows = [{
    queryid: '42',
    statement_text: 'SELECT * FROM todos',
    comment_metadata: { controller: 'todos', action: 'index' },
    total_exec_count: 3,
    avg_exec_time_ms: 12.5
  }];

  expect(formatFinding(rows[0])).toContain('controller=todos');
  expect(formatFinding(rows[0])).not.toContain('source_file');
});
```

```python
def test_clickhouse_schema_exposes_comment_metadata():
    columns = fetch_columns("query_events")

    assert "comment_metadata" in columns
    assert "source_file" not in columns
```

- [ ] **Step 2: Run the targeted checkpoint tests and verify they fail**

Run: `node --import tsx --test test/tools/clickhouse_tool.test.ts`

Expected: FAIL because queries and formatting still expect source columns.

Run: `node --import tsx --test agent/test/clickhouse_tool.test.ts`

Expected: FAIL for the same reason.

Run: `python3 -m pytest tests/smoke/test_clickhouse_schema.py -v`

Expected: FAIL because the smoke assertions still reference the old columns.

- [ ] **Step 3: Implement the minimal checkpoint query changes**

```typescript
SELECT
  queryid,
  statement_text,
  comment_metadata,
  total_exec_count,
  avg_exec_time_ms
FROM query_intervals
```

```typescript
function metadataValue(row: { comment_metadata?: Record<string, string> }, key: string): string | undefined {
  return row.comment_metadata?.[key];
}
```

Update any remaining joins or formatting logic to pull `source_location` from `comment_metadata['source_location']` only when needed for display, not as a required schema column.

- [ ] **Step 4: Run the targeted checkpoint tests again**

Run: `node --import tsx --test test/tools/clickhouse_tool.test.ts`

Expected: PASS

Run: `node --import tsx --test agent/test/clickhouse_tool.test.ts`

Expected: PASS

Run: `python3 -m pytest tests/smoke/test_clickhouse_schema.py -v`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git -C /home/bjw/checkpoint/.worktrees/collector-correctness-checkpoint add extensions/db-specialist.ts
git -C /home/bjw/checkpoint/.worktrees/collector-correctness-checkpoint add test/tools/clickhouse_tool.test.ts
git -C /home/bjw/checkpoint/.worktrees/collector-correctness-checkpoint add agent/test/clickhouse_tool.test.ts
git -C /home/bjw/checkpoint/.worktrees/collector-correctness-checkpoint add tests/smoke/test_clickhouse_schema.py
git -C /home/bjw/checkpoint/.worktrees/collector-correctness-checkpoint commit -m "feat: read collector comment metadata"
```

## Task 5: Cross-Repo Verification

**Files:**
- No code changes expected
- Verify: `/home/bjw/checkpoint-collector`
- Verify: `/home/bjw/checkpoint`

- [ ] **Step 1: Run collector-side verification**

Run: `bundle exec ruby test/query_comment_parser_test.rb test/collector_test.rb test/log_ingester_test.rb test/runtime_orchestration_test.rb test/sql/clickhouse_schema_test.rb`

Expected: all PASS

- [ ] **Step 2: Run checkpoint-side verification**

Run: `node --import tsx --test test/tools/clickhouse_tool.test.ts agent/test/clickhouse_tool.test.ts`

Expected: PASS

Run: `python3 -m pytest tests/smoke/test_clickhouse_schema.py -v`

Expected: PASS

- [ ] **Step 3: Run the walkthrough-neutral final check**

Run: `git status --short`

Expected: only intentional files remain modified; `collector-correctness-walkthrough.md` may remain uncommitted if Brett still wants it left out.

- [ ] **Step 4: Commit any final plan-driven cleanups if needed**

```bash
git add <only-if-needed>
git commit -m "test: finish comment metadata verification"
```

If there are no code changes in this task, skip the commit.

## Spec Coverage Check

- Generic metadata map on snapshots and raw logs: Tasks 1, 2, 3
- Removal of `source_file` / `source_location` as first-class columns: Tasks 2, 3, 4
- Snapshot-vs-raw-log semantics preserved: Tasks 3, 4
- Cross-repo compatibility with the checkpoint worktree: Task 4
- Final verification: Task 5

## Placeholder Scan

- No `TBD` / `TODO` placeholders remain in this plan.
- Every code-changing task includes explicit file paths, test commands, and commit steps.
- This plan intentionally avoids revisiting already-completed scheduler work from the first plan.
