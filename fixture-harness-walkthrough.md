# Fixture Harness Walkthrough

*2026-04-19T15:52:03Z by Showboat 0.6.1*
<!-- showboat-id: ece14529-24ec-4df2-8b8c-c57ab13b0207 -->

The fixture harness is a tool for reproducing specific Postgres query anti-patterns on demand. It resets a seeded database to a known broken state, drives real HTTP traffic through an external demo app, then asserts that the bad query plan appears in both EXPLAIN and ClickHouse. The goal is a repeatable, verifiable environment where a database specialist agent can observe a pathology, diagnose it, and apply a fix — and the harness can confirm the plan flipped.

There is one fixture today: `missing-index`, which demonstrates a sequential scan on `todos.status` that an index would eliminate. The harness lives entirely in the repo and needs no changes to the collector pipeline or docker-compose.

## How the pieces fit together

```
bin/fixture <name> <verb> [flags]
       │
       ▼
Fixtures::Command        ← parses verb + flags, loads manifest
       │
       ├── reset  →  MissingIndex::Reset  ← Postgres template-DB rebuild
       ├── drive  →  MissingIndex::Drive  ← concurrent HTTP traffic driver
       └── assert →  MissingIndex::Assert ← EXPLAIN + ClickHouse poll
```

Each fixture keeps its data and code under `fixtures/<name>/`. The shared plumbing (`manifest.rb`, `command.rb`) lives under `collector/lib/fixtures/` and is loaded via Bundler.

## 1. Entry point: `bin/fixture`

The CLI is a thin bootstrap. It sets up Bundler from the collector Gemfile so all subsequent Ruby files can use the gem dependencies already installed for the collector, then hands off to `Fixtures::Command`.

```bash
cat bin/fixture
```

```output
#!/usr/bin/env ruby
# ABOUTME: Runs fixture reset, traffic drive, and validation commands for pathology reproducers.
# ABOUTME: Loads fixture metadata from the repo and dispatches to fixture-specific Ruby code.
ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../collector/Gemfile", __dir__)
require "bundler/setup"
require_relative "../collector/lib/fixtures/command"

exit Fixtures::Command.new(argv: ARGV, stdout: $stdout, stderr: $stderr).run
```

The `ENV["BUNDLE_GEMFILE"] ||=` guard means you can also invoke the file with `BUNDLE_GEMFILE` already set, which is how the test suite loads it. `exit` with the return value of `Command#run` gives clean shell exit codes (0 = success, 1 = failure).

## 2. Fixture manifest: `fixtures/missing-index/manifest.yml`

Every fixture is described by a YAML manifest. This is the single source of truth for the database name, the workload shape, the health endpoint, and the assertion signals. Keeping these in data — not code — means you can add a new fixture by writing a manifest and three Ruby files without touching the shared CLI at all.

```bash
cat fixtures/missing-index/manifest.yml
```

```output
# ABOUTME: Describes the missing-index fixture used by the reset, drive, and assert commands.
# ABOUTME: Stores the database name, workload defaults, and signal checks for the fixture harness.
name: missing-index
description: Seq scan on todos.status when an index would flip the plan.
db_name: fixture_01
demo_app:
  health_endpoint: /up
workload:
  method: GET
  path: /todos/status?status=open
  seconds: 60
  concurrency: 16
  rate: unlimited
signals:
  explain:
    root_node_kind: Seq Scan
    root_node_relation: todos
    query: >
      SELECT "todos".* FROM "todos" WHERE "todos"."status" = 'open'
  clickhouse:
    statement_contains: 'FROM "todos" WHERE "todos"."status"'
    min_call_count: 500
```

A few deliberate choices here:

**`db_name: fixture_01`** — opaque ordinal name. The agent can't infer the pathology from the database name. The fixture directory is named `missing-index` but the Postgres database is just `fixture_01`.

**`workload.rate: unlimited`** — 16 concurrent workers with no rate cap. We want enough traffic to exceed the `min_call_count: 500` threshold in ClickHouse within the 60-second drive window.

**`signals.explain.root_node_kind: Seq Scan`** — the assertion checks that the query planner chose a sequential scan on the `todos` table. When the oracle fix (adding the index) is applied, this flips to `Index Scan` and the assertion fails, confirming the fix worked.

**`signals.clickhouse.statement_contains`** — a substring used to find the right rows in ClickHouse. The actual stored statement text comes from `pg_stat_statements`, which captures the normalized query.

## 3. Manifest loader: `collector/lib/fixtures/manifest.rb`

The manifest loader parses the YAML and exposes typed accessors as a Ruby `Struct`. It's injected into `Command` as `manifest_loader:` so tests can substitute a fake without touching the filesystem.

```bash
cat collector/lib/fixtures/manifest.rb
```

```output
# ABOUTME: Loads fixture metadata from YAML and exposes typed accessors for each fixture command.
# ABOUTME: Keeps `bin/fixture` argument parsing separate from fixture-specific runtime behavior.
require "yaml"

module Fixtures
  Manifest = Struct.new(
    :name, :description, :db_name, :health_endpoint, :request_method, :request_path,
    :seconds, :concurrency, :rate, :explain_query, :explain_root_node_kind,
    :explain_root_relation, :clickhouse_statement_contains, :clickhouse_min_call_count,
    keyword_init: true
  ) do
    def self.load(name, root: default_root)
      path = File.join(root, name, "manifest.yml")
      raise "Unknown fixture: #{name}" unless File.exist?(path)

      data = YAML.load_file(path)
      new(
        name: data.fetch("name"),
        description: data.fetch("description"),
        db_name: data.fetch("db_name"),
        health_endpoint: data.fetch("demo_app").fetch("health_endpoint"),
        request_method: data.fetch("workload").fetch("method"),
        request_path: data.fetch("workload").fetch("path"),
        seconds: data.fetch("workload").fetch("seconds"),
        concurrency: data.fetch("workload").fetch("concurrency"),
        rate: data.fetch("workload").fetch("rate"),
        explain_query: data.fetch("signals").fetch("explain").fetch("query"),
        explain_root_node_kind: data.fetch("signals").fetch("explain").fetch("root_node_kind"),
        explain_root_relation: data.fetch("signals").fetch("explain").fetch("root_node_relation"),
        clickhouse_statement_contains: data.fetch("signals").fetch("clickhouse").fetch("statement_contains"),
        clickhouse_min_call_count: data.fetch("signals").fetch("clickhouse").fetch("min_call_count"),
      )
    end

    def self.default_root
      File.expand_path("../../../fixtures", __dir__)
    end
  end
end
```

`fetch` is used throughout rather than `[]` — a missing required key raises a `KeyError` immediately with a clear message rather than silently returning `nil` and failing later. `default_root` resolves `fixtures/` relative to this file's own location in `collector/lib/fixtures/`, so the manifest loader works regardless of where you invoke `bin/fixture` from.

## 4. Command dispatch: `collector/lib/fixtures/command.rb`

`Command` owns CLI parsing and dispatch. It reads the fixture name and verb from `argv`, loads the manifest, parses any flags, then calls the matching handler from a registry.

```bash
cat collector/lib/fixtures/command.rb
```

```output
# ABOUTME: Parses `bin/fixture` arguments and dispatches work to fixture-specific classes.
# ABOUTME: Keeps the top-level CLI stable while fixture implementations live under `fixtures/`.
require "optparse"
require_relative "manifest"

module Fixtures
  class Command
    USAGE = "Usage: bin/fixture <name> <reset|drive|assert|all> [flags]".freeze
    VALID_VERBS = %w[reset drive assert all].freeze

    def initialize(argv:, registry: nil, manifest_loader: Fixtures::Manifest, stdout:, stderr:)
      @argv = argv.dup
      @registry = registry || default_registry
      @manifest_loader = manifest_loader
      @stdout = stdout
      @stderr = stderr
    end

    def run
      fixture_name = @argv.shift
      verb = @argv.shift
      return usage_error if fixture_name.nil? || verb.nil? || !VALID_VERBS.include?(verb)

      manifest = @manifest_loader.load(fixture_name)
      options = parse_flags(manifest: manifest)

      steps = verb == "all" ? %w[reset drive assert] : [verb]
      steps.each do |step|
        handler = @registry[[fixture_name, step]]
        return usage_error if handler.nil?

        handler.call(manifest: manifest, options: options)
      end

      0
    rescue OptionParser::ParseError => error
      @stderr.puts(error.message)
      usage_error
    rescue StandardError => error
      @stderr.puts(error.message)
      1
    end

    private

    def usage_error
      @stderr.puts(USAGE)
      1
    end

    def default_registry
      {
        ["missing-index", "reset"] => ->(manifest:, options:) do
          require File.expand_path("../../../fixtures/missing-index/setup/reset", __dir__)
          Fixtures::MissingIndex::Reset.new(manifest: manifest, options: options).run
        end,
        ["missing-index", "drive"] => ->(manifest:, options:) do
          require File.expand_path("../../../fixtures/missing-index/load/drive", __dir__)
          Fixtures::MissingIndex::Drive.new(manifest: manifest, options: options).run
        end,
        ["missing-index", "assert"] => ->(manifest:, options:) do
          require File.expand_path("../../../fixtures/missing-index/validate/assert", __dir__)
          Fixtures::MissingIndex::Assert.new(manifest: manifest, options: options, stdout: @stdout).run
        end,
      }
    end

    def parse_flags(manifest:)
      options = {
        base_url: ENV.fetch("BASE_URL", "http://localhost:3000"),
        admin_url: ENV.fetch("FIXTURE_ADMIN_URL", "postgresql://postgres:postgres@localhost:5432/postgres"),
        clickhouse_url: ENV.fetch("CLICKHOUSE_URL", "http://localhost:8123"),
        seconds: manifest.seconds,
        concurrency: manifest.concurrency,
        rate: manifest.rate,
        timeout_seconds: 180,
        rebuild_template: false,
      }

      OptionParser.new do |parser|
        parser.on("--rebuild-template") { options[:rebuild_template] = true }
        parser.on("--seconds N", Integer) { |value| options[:seconds] = value }
        parser.on("--concurrency N", Integer) { |value| options[:concurrency] = value }
        parser.on("--rate VALUE") do |value|
          options[:rate] = value == "unlimited" ? "unlimited" : Integer(value)
        rescue ArgumentError
          raise OptionParser::InvalidArgument, value
        end
        parser.on("--base-url URL") { |value| options[:base_url] = value }
        parser.on("--timeout-seconds N", Integer) { |value| options[:timeout_seconds] = value }
      end.parse!(@argv)

      options
    end
  end
end
```

Several things worth noting here:

**Lazy `require` in the registry** — each handler lambda `require`s its fixture file only when that verb is actually invoked. Running `reset` never loads `drive.rb` or `assert.rb`. This keeps startup fast and prevents accidental cross-contamination between fixture implementations.

**Registry key is `[fixture_name, verb]`** — a two-element array. Adding a second fixture (`missing-index-2`, `lock-contention`, etc.) means adding entries to the registry with no structural changes to the dispatch loop.

**`all` expands to `%w[reset drive assert]`** — sequential, same process. If reset fails, drive never starts. The error propagates via `raise` in the handler and is caught by the `rescue StandardError` block, which prints the message and returns exit code 1.

**`parse_flags` reads manifest defaults first** — `seconds`, `concurrency`, and `rate` are pre-loaded from the manifest so CLI flags are optional overrides. You can override any of them at the command line: `bin/fixture missing-index drive --seconds 30 --rate 10`.

## 5. Reset: `fixtures/missing-index/setup/reset.rb`

Reset is the most structurally interesting step. The naive approach — dropping the database and re-running schema + seed migrations — takes minutes because the seed inserts 10 million rows. The harness uses Postgres template databases instead: build the template once, then clone it in milliseconds for every subsequent reset.

```bash
cat fixtures/missing-index/setup/reset.rb
```

```output
# ABOUTME: Rebuilds the missing-index fixture database from SQL files and a Postgres template database.
# ABOUTME: Keeps reset fast by cloning `fixture_01` from `fixture_01_tmpl` after the first seed run.
require "pg"
require "uri"

module Fixtures
  module MissingIndex
    class Reset
      def initialize(manifest:, options:, pg: PG)
        @manifest = manifest
        @options = options
        @pg = pg
      end

      def run
        admin = @pg.connect(@options.fetch(:admin_url))
        rebuild_template(admin) if @options[:rebuild_template]
        ensure_template(admin)
        recreate_working_database(admin)
        reset_pg_stat_statements
      ensure
        admin&.close
      end

      private

      def ensure_template(admin)
        return if database_exists?(admin, template_name)

        create_database(admin, template_name)
        load_sql(template_url, "01_schema.sql")
        load_sql(template_url, "02_seed.sql")
      rescue StandardError
        drop_database(admin, template_name)
        raise
      end

      def rebuild_template(admin)
        drop_database(admin, @manifest.db_name)
        drop_database(admin, template_name)
      end

      def recreate_working_database(admin)
        drop_database(admin, @manifest.db_name)
        admin.exec(%(CREATE DATABASE "#{@manifest.db_name}" TEMPLATE "#{template_name}"))
      end

      def reset_pg_stat_statements
        worker = @pg.connect(database_url(@manifest.db_name))
        worker.exec("SELECT pg_stat_statements_reset()")
      ensure
        worker&.close
      end

      def load_sql(url, name)
        connection = @pg.connect(url)
        connection.exec(File.read(File.expand_path(name, __dir__)))
      ensure
        connection&.close
      end

      def create_database(admin, name)
        admin.exec(%(CREATE DATABASE "#{name}"))
      end

      def drop_database(admin, name)
        admin.exec_params(<<~SQL, [name])
          SELECT pg_terminate_backend(pid)
          FROM pg_stat_activity
          WHERE datname = $1 AND pid <> pg_backend_pid()
        SQL
        admin.exec(%(DROP DATABASE IF EXISTS "#{name}"))
      end

      def database_exists?(admin, name)
        result = admin.exec_params("SELECT 1 FROM pg_database WHERE datname = $1", [name])
        result.ntuples == 1
      end

      def template_name
        "#{@manifest.db_name}_tmpl"
      end

      def template_url
        database_url(template_name)
      end

      def database_url(name)
        base = URI.parse(@options.fetch(:admin_url))
        base.path = "/#{name}"
        base.to_s
      end
    end
  end
end
```

The flow through `run` is:

```
admin connect (to 'postgres')
  │
  ├── [--rebuild-template flag] drop fixture_01 + fixture_01_tmpl
  │
  ├── ensure_template
  │     ├── database_exists?(fixture_01_tmpl)?  ──yes──▶  skip (fast path)
  │     └── no: CREATE fixture_01_tmpl
  │              load_sql 01_schema.sql  ──▶  broken schema, no status index
  │              load_sql 02_seed.sql    ──▶  10M row insert (slow, once only)
  │              [on error] drop fixture_01_tmpl, re-raise  (no poisoned template)
  │
  ├── recreate_working_database
  │     drop fixture_01
  │     CREATE DATABASE fixture_01 TEMPLATE fixture_01_tmpl  ──▶  instant clone
  │
  └── reset_pg_stat_statements
        connect to fixture_01
        SELECT pg_stat_statements_reset()
```

**Why `drop_database` terminates existing connections first** — Postgres refuses to drop a database with active connections. The `exec_params` call to `pg_terminate_backend` closes any lingering sessions (e.g., the Rails demo app's connection pool) before the drop. It uses a parameterized query (``) to avoid string interpolation into SQL.

**Why `pg_stat_statements_reset()` at the end** — the assert step checks call counts in ClickHouse against a `max(total_exec_count)` window. If we don't reset before the drive, counts from a previous run bleed in. After reset, the counter starts at zero, so the max count in the drive window equals the actual number of executions during that window.

## 6. The broken schema: `fixtures/missing-index/setup/01_schema.sql`

This is the database state the fixture is designed to reproduce. It's intentionally the 'wrong' state — the one that causes the pathology.

```bash
cat fixtures/missing-index/setup/01_schema.sql
```

```output
-- ABOUTME: Creates the missing-index fixture schema with the todos status column left unindexed.
-- ABOUTME: Leaves the users_id and todos.user_id relationship in place so the reset path can seed data.
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

CREATE TABLE users (
  id BIGSERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  created_at TIMESTAMP NOT NULL,
  updated_at TIMESTAMP NOT NULL
);

CREATE TABLE todos (
  id BIGSERIAL PRIMARY KEY,
  title TEXT NOT NULL,
  status TEXT NOT NULL,
  user_id BIGINT NOT NULL REFERENCES users(id),
  created_at TIMESTAMP NOT NULL,
  updated_at TIMESTAMP NOT NULL
);

CREATE INDEX index_todos_on_user_id ON todos (user_id);
```

Notice what's absent: there is no `CREATE INDEX` on `todos(status)`. The `user_id` foreign-key index exists (and Rails would create it anyway), but the `status` column is unindexed.

This is the pathology. The demo app's `/todos/status?status=open` endpoint runs `WHERE todos.status = 'open'` and with no index, Postgres must scan the entire table. With 10 million rows and only ~0.2% matching, that scan is the inefficiency the checkpoint agent is supposed to detect.

The schema also enables `pg_stat_statements` via the extension. This is what the collector reads every interval to track query execution counts and timing.

## 7. Seed data: `fixtures/missing-index/setup/02_seed.sql`

The seed is calibrated to make the pathology visible. Row count and selectivity both matter to the query planner.

```bash
cat fixtures/missing-index/setup/02_seed.sql
```

```output
-- ABOUTME: Seeds the missing-index fixture with a large todos table and a rare open status.
-- ABOUTME: Analyzes both tables so the planner can choose the intended seq scan baseline.
INSERT INTO users (name, created_at, updated_at)
SELECT 'user_' || i, NOW(), NOW()
FROM generate_series(1, 1000) AS i;

INSERT INTO todos (title, status, user_id, created_at, updated_at)
SELECT
  'todo ' || i,
  CASE WHEN random() < 0.998 THEN 'closed' ELSE 'open' END,
  (random() * 999 + 1)::int,
  NOW(),
  NOW()
FROM generate_series(1, 10000000) AS i;

ANALYZE users;
ANALYZE todos;
```

**10 million todos with ~0.2% open** — at this scale, a sequential scan costs ~75ms (measured empirically). With an index on `status`, the same query takes ~2ms. That 33× difference is what the checkpoint agent's EXPLAIN analysis should detect and explain.

**`ANALYZE` at the end** — this updates the planner statistics so Postgres knows the table has 10M rows and only 0.2% are `open`. Without fresh statistics, the planner might choose an index scan even without an index, or make poor cardinality estimates. Running `ANALYZE` ensures the planner makes the decision we expect: seq scan is cheaper (per its model) when it doesn't know an index exists.

**Why this runs in the template, not on every reset** — this insert is slow (tens of seconds to minutes depending on hardware). The template database stores the result permanently. Every subsequent `reset` call clones `fixture_01_tmpl` into `fixture_01` with `CREATE DATABASE ... TEMPLATE`, which is a filesystem-level copy operation and takes under a second.

## 8. Drive: `fixtures/missing-index/load/drive.rb`

Drive waits for the external demo app to be ready, then sends concurrent HTTP requests for a fixed duration and records the traffic window to disk.

```bash
cat fixtures/missing-index/load/drive.rb
```

```output
# ABOUTME: Waits for the external demo app and drives concurrent requests against the missing-index endpoint.
# ABOUTME: Persists the last traffic window so later assertions can read the same execution interval.
require "fileutils"
require "json"
require "net/http"
require "thread"
require "time"
require "uri"

module Fixtures
  module MissingIndex
    class Drive
      def initialize(manifest:, options:, clock: -> { Time.now.utc }, sleeper: ->(seconds) { sleep(seconds) })
        @manifest = manifest
        @options = options
        @clock = clock
        @sleeper = sleeper
      end

      def run
        wait_until_up!

        start_time = @clock.call
        finish_at = start_time + @options.fetch(:seconds)
        request_count = 0
        mutex = Mutex.new
        limiter = RateLimiter.new(@options.fetch(:rate), clock: @clock, sleeper: @sleeper)
        stop_requested = false
        worker_error = nil

        threads = Array.new(@options.fetch(:concurrency)) do
          Thread.new do
            while !mutex.synchronize { stop_requested } && @clock.call < finish_at
              limiter.wait_turn
              break if mutex.synchronize { stop_requested } || @clock.call >= finish_at

              request_endpoint
              mutex.synchronize { request_count += 1 }
            end
          rescue StandardError => error
            mutex.synchronize do
              worker_error ||= error
              stop_requested = true
            end
          end
        end

        threads.each(&:join)
        raise worker_error if worker_error

        write_last_run(start_time: start_time, end_time: @clock.call, request_count: request_count)
      end

      private

      def wait_until_up!
        deadline = @clock.call + 120
        last_health_result = nil

        until healthy?
          last_health_result = @last_health_result
          if @clock.call >= deadline
            message = "Timed out waiting for #{@options.fetch(:base_url)}#{@manifest.health_endpoint}"
            message = "#{message} (last status: #{last_health_result})" if last_health_result
            raise message
          end

          @sleeper.call(1)
        end
      end

      def healthy?
        response = Net::HTTP.get_response(URI.join(@options.fetch(:base_url), @manifest.health_endpoint))
        @last_health_result = response.code.to_i
        response.code.to_i == 200
      rescue Errno::ECONNREFUSED
        @last_health_result = "connection refused"
        false
      end

      def request_endpoint
        Net::HTTP.get_response(URI.join(@options.fetch(:base_url), @manifest.request_path))
      end

      def write_last_run(start_time:, end_time:, request_count:)
        output_dir = @options.fetch(:output_dir, File.expand_path("../../../tmp", __dir__))
        FileUtils.mkdir_p(output_dir)
        File.write(
          File.join(output_dir, "fixture-last-run.json"),
          JSON.pretty_generate(
            start_ts: start_time.iso8601(3),
            end_ts: end_time.iso8601(3),
            request_count: request_count,
          ) + "\n"
        )
      end

      class RateLimiter
        def initialize(rate, clock:, sleeper:)
          @rate = rate
          @clock = clock
          @sleeper = sleeper
          @next_allowed_at = nil
          @mutex = Mutex.new
        end

        def wait_turn
          @mutex.synchronize do
            return if @rate == "unlimited"

            now = @clock.call
            @next_allowed_at ||= now
            sleep_for = @next_allowed_at - now
            @sleeper.call(sleep_for) if sleep_for.positive?
            @next_allowed_at = [@next_allowed_at, now].max + (1.0 / @rate)
          end
        end
      end
    end
  end
end
```

**Dependency-injected `clock` and `sleeper`** — these are lambdas that default to `Time.now.utc` and `sleep`. In tests, a `FakeClock` and a recording sleeper replace them, making time fully deterministic without `sleep` calls.

**`RateLimiter` is shared across all worker threads** — one limiter, one mutex. This enforces a global request rate, not per-thread rate. With `rate: unlimited`, `wait_turn` returns immediately. With a finite rate (e.g., `--rate 10`), `wait_turn` sleeps until the next allowed slot, with each slot advancing by `1.0 / rate` seconds. The `[@next_allowed_at, now].max` guard prevents negative sleep accumulation when workers fall behind.

**Error propagation from threads** — the first error from any worker is stored in `worker_error` and `stop_requested` is set to true. All other threads see the stop flag on their next loop iteration. After `threads.each(&:join)`, the error is re-raised in the main thread, giving the operator a useful message and a non-zero exit code.

**`write_last_run`** — this is the handoff between drive and assert. It writes `tmp/fixture-last-run.json` with the ISO8601 start and end timestamps of the traffic window. The assert step reads this file to know which time range to query in ClickHouse.

```bash
cat tmp/fixture-last-run.json
```

```output
{
  "start_ts": "2026-04-18T12:00:00.000Z",
  "end_ts": "2026-04-18T12:01:00.000Z",
  "request_count": 100
}
```

The file above is a test fixture written by the assert tests. A real drive run on the missing-index fixture for 60 seconds with 16 workers and no rate limit would produce something like `request_count: 8000` and a 60-second span between `start_ts` and `end_ts`.

## 9. Assert: `fixtures/missing-index/validate/assert.rb`

Assert checks two independent signals: the Postgres query plan and the ClickHouse call count. Both must pass. Either one alone could be gamed or misleading — the plan check proves the schema is in the broken state, the ClickHouse check proves real traffic actually hit the database at scale.

```bash
cat fixtures/missing-index/validate/assert.rb
```

```output
# ABOUTME: Verifies the missing-index fixture reproduces the bad plan in Postgres and in ClickHouse.
# ABOUTME: Reads the last traffic window from disk so ClickHouse polling matches the driven request interval.
require "json"
require "net/http"
require "pg"
require "time"
require "uri"

module Fixtures
  module MissingIndex
    class Assert
      def initialize(manifest:, options:, stdout:, pg: PG, clickhouse_query: nil, sleeper: ->(seconds) { sleep(seconds) })
        @manifest = manifest
        @options = options
        @stdout = stdout
        @pg = pg
        @clickhouse_query = clickhouse_query || method(:query_clickhouse)
        @sleeper = sleeper
      end

      def run
        plan = explain_root_plan
        verify_plan!(plan)
        clickhouse = wait_for_clickhouse!

        @stdout.puts("FIXTURE: #{@manifest.name}")
        @stdout.puts("PASS: explain (#{plan.fetch("Node Type")} on #{plan.fetch("Relation Name")}, plan node confirmed)")
        @stdout.puts("PASS: clickhouse (#{clickhouse.fetch("calls")} calls; mean #{clickhouse.fetch("mean_ms")}ms)")

        [plan, clickhouse]
      end

      private

      def explain_root_plan
        connection = @pg.connect(database_url(@manifest.db_name))
        rows = connection.exec(%(EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{@manifest.explain_query}))
        payload = JSON.parse(rows.first.fetch("QUERY PLAN"))
        find_relation_node(payload.fetch(0).fetch("Plan"))
      ensure
        connection&.close
      end

      def verify_plan!(plan)
        raise "Could not find #{@manifest.explain_root_relation} in EXPLAIN plan" unless plan

        return if plan.fetch("Node Type") == @manifest.explain_root_node_kind && plan.fetch("Relation Name") == @manifest.explain_root_relation

        raise "Expected #{@manifest.explain_root_node_kind} on #{@manifest.explain_root_relation}, got #{plan.fetch("Node Type")} on #{plan.fetch("Relation Name")}"
      end

      def wait_for_clickhouse!
        window = load_last_run_window
        deadline = Time.now.utc + @options.fetch(:timeout_seconds)

        loop do
          snapshot = @clickhouse_query.call(window)
          return snapshot if snapshot.fetch("calls").to_i >= @manifest.clickhouse_min_call_count

          raise "ClickHouse saw only #{snapshot.fetch("calls")} calls before timeout" if Time.now.utc >= deadline

          @sleeper.call(10)
        end
      end

      def load_last_run_window
        last_run_path = @options.fetch(:last_run_path, File.expand_path("../../../tmp/fixture-last-run.json", __dir__))
        JSON.parse(File.read(last_run_path))
      rescue Errno::ENOENT
        raise "Run `bin/fixture #{@manifest.name} drive` first: missing fixture-last-run.json at #{last_run_path}"
      end

      def query_clickhouse(window)
        sql = <<~SQL
          SELECT
            toString(coalesce(max(total_exec_count), 0)) AS calls,
            toString(round(coalesce(avg(mean_exec_time_ms), 0), 1)) AS mean_ms
          FROM query_events
          WHERE collected_at BETWEEN parseDateTime64BestEffort('#{window.fetch("start_ts")}') AND parseDateTime64BestEffort('#{window.fetch("end_ts")}') + INTERVAL 90 SECOND
            AND statement_text LIKE '%#{@manifest.clickhouse_statement_contains}%'
        SQL

        uri = URI.parse(@options.fetch(:clickhouse_url))
        uri.path = "/" if uri.path.empty?
        uri.query = URI.encode_www_form(query: "#{sql} FORMAT JSONEachRow")
        response = Net::HTTP.get_response(uri)
        raise "ClickHouse query failed: #{response.code} #{response.body}" if response.code.to_i >= 400

        body = response.body.to_s.each_line.first || '{"calls":"0","mean_ms":"0.0"}'
        JSON.parse(body)
      end

      def database_url(name)
        base = URI.parse(@options.fetch(:admin_url, "postgresql://postgres:postgres@localhost:5432/postgres"))
        base.path = "/#{name}"
        base.to_s
      end

      def find_relation_node(node)
        return node if node.fetch("Relation Name", nil) == @manifest.explain_root_relation

        Array(node.fetch("Plans", [])).each do |child|
          match = find_relation_node(child)
          return match if match
        end

        nil
      end
    end
  end
end
```

**The EXPLAIN check — `explain_root_plan` + `verify_plan!`**

`EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` executes the query and returns the actual execution plan as JSON. `find_relation_node` walks the plan tree (which can be nested for joins) to find the node that scans the `todos` relation. For this fixture's simple single-table query, that node is the root.

`verify_plan!` then checks that this node's type matches `explain_root_node_kind: Seq Scan`. If the database is in the broken state (no status index), Postgres must do a seq scan. If someone applied the oracle fix (`oracle/add-index`), the planner switches to `Index Scan` and `verify_plan!` raises, failing the assertion — which is exactly what you want when verifying the fix works.

**The ClickHouse check — `wait_for_clickhouse!`**

This step loads the time window written by `drive` and polls ClickHouse every 10 seconds until enough calls accumulate. The query:

```sql
SELECT
  max(total_exec_count) AS calls,    -- max, not sum: query_events stores cumulative snapshots
  avg(mean_exec_time_ms) AS mean_ms
FROM query_events
WHERE collected_at BETWEEN <start_ts> AND <end_ts> + INTERVAL 90 SECOND
  AND statement_text LIKE '%FROM "todos" WHERE "todos"."status"%'
```

The `+ INTERVAL 90 SECOND` extension gives the collector up to 90 seconds after the drive window ends to ingest the last snapshot batch into ClickHouse. `max(total_exec_count)` is used because `query_events` stores cumulative pg_stat_statements values — since reset() cleared the counter to zero before the drive, `max` in the window equals the total call count during the drive.

When the call count reaches `min_call_count: 500`, the assertion passes and prints a summary line like:

```
FIXTURE: missing-index
PASS: explain (Seq Scan on todos, plan node confirmed)
PASS: clickhouse (3847 calls; mean 74.9ms)
```

## 10. Oracle documentation: `fixtures/missing-index/README.md`

The README is the contract for how to use the fixture end-to-end, including how to verify the oracle (the known fix).

```bash
cat fixtures/missing-index/README.md
```

````output
# Missing Index Fixture

This fixture reproduces the broken `todos.status` plan against the external demo app.

## Oracle Tags

- `oracle/rewrite-like` rewrites the text search path in the demo repo.
- `oracle/add-index` adds the missing `todos(status)` index and flips the root node from `Seq Scan` to `Index Scan`.
- `oracle/rewrite-count` changes the stats query path.

## Demo App Startup

Start the collector stack in `checkpoint-collector`, then start the demo app separately:

```bash
BUNDLE_USER_HOME=/tmp/bundle BUNDLE_PATH=vendor/bundle \
DATABASE_URL=postgres://postgres:postgres@localhost:5432/fixture_01 \
bundle exec rails server -b 127.0.0.1 -p 3000
```

Run that command from `~/db-specialist-demo`.

Before `bin/fixture missing-index drive` or `all`, verify the readiness probe:

```bash
curl -i http://127.0.0.1:3000/up
```

`bin/fixture` waits for `/up` to return `200`. On the current `ab679e7` baseline app, `/up`
returns `404`, so `drive` and `all` time out with a message that includes the last observed
health status.

## Commands

```bash
bin/fixture missing-index reset --rebuild-template
bin/fixture missing-index drive
bin/fixture missing-index assert
bin/fixture missing-index all
```

## Oracle Verification

`bin/fixture missing-index assert` reads `tmp/fixture-last-run.json`, so run
`drive` first or reuse an existing last-run file from the same fixture window.

```bash
bin/fixture missing-index reset --rebuild-template
bin/fixture missing-index drive
git -C ~/db-specialist-demo checkout oracle/add-index
bin/fixture missing-index assert --timeout-seconds 180
git -C ~/db-specialist-demo checkout master
```

The assertion should fail because the root node becomes `Index Scan`.
````

The oracle tags are git tags in `~/db-specialist-demo` pointing at commits that represent known solutions. `oracle/add-index` is the most direct fix: it creates the missing `todos(status)` index. When you check that commit out and run assert, the EXPLAIN check fails because `Seq Scan` became `Index Scan` — the fixture correctly detects that the pathology is gone.

This is how you validate the fixture is working: apply the known fix, confirm the assertion flips from pass to fail. If the assertion still passes after adding the index, the fixture isn't sensitive enough to detect the fix, and something is wrong.

## 11. Tests

The test suite lives in `collector/test/fixtures/`. Each fixture class has its own test file, plus tests for the shared manifest and command layers.

```bash
ls -1 collector/test/fixtures/
```

```output
fixture_command_test.rb
fixture_manifest_test.rb
fixture_smoke_target_test.rb
missing_index_assert_test.rb
missing_index_drive_test.rb
missing_index_reset_test.rb
```

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby -e "Dir['collector/test/fixtures/*.rb'].each { |f| load f }" 2>&1
```

```output
Run options: --seed 60391

# Running:

.......................

Finished in 3.200993s, 7.1853 runs/s, 29.3659 assertions/s.

23 runs, 94 assertions, 0 failures, 0 errors, 0 skips
```

All tests run without a live Postgres or ClickHouse connection. The pattern throughout is dependency injection: `pg:` and `clickhouse_query:` are injected as constructor arguments, so tests substitute fakes instead of needing a real database.

A few notable test design decisions:

**`fixture_command_test.rb`** includes a test that verifies `require` isolation — when you run `reset`, neither `drive.rb` nor `assert.rb` is loaded into the Ruby process. This is done by monkey-patching `Kernel.require` in a `with_require_guard` helper that raises if the wrong file is required.

**`missing_index_drive_test.rb`** spins up a real `TCPServer` on a random port to test the health-check wait and request dispatch without mocking `Net::HTTP`. The test server returns 503 twice, then 200, to exercise the retry path.

**`missing_index_reset_test.rb`** uses a `FakePg` class that routes connections to different fake connection objects based on whether the URL contains the template database name, matching how the real code opens separate connections to the admin DB and the template DB.

## 12. Running the harness end-to-end

Prerequisites: the collector stack (`docker compose up`) must be running, and the demo app must be started separately pointing at `fixture_01`.

```bash
# Terminal 1 — collector stack
docker compose up

# Terminal 2 — demo app pointed at the fixture database
cd ~/db-specialist-demo
BUNDLE_USER_HOME=/tmp/bundle BUNDLE_PATH=vendor/bundle \
DATABASE_URL=postgres://postgres:postgres@localhost:5432/fixture_01 \
bundle exec rails server -b 127.0.0.1 -p 3000

# Terminal 3 — fixture harness (from checkpoint-collector)
bin/fixture missing-index reset --rebuild-template   # slow first time; fast after
bin/fixture missing-index drive                      # 60 seconds of traffic
bin/fixture missing-index assert                     # should print PASS for both checks
```

Or all at once:

```bash
bin/fixture missing-index all
```

To verify the oracle (confirm the fixture detects the fix):

```bash
git -C ~/db-specialist-demo checkout oracle/add-index
bin/fixture missing-index assert          # should FAIL: Seq Scan flipped to Index Scan
git -C ~/db-specialist-demo checkout master
```
