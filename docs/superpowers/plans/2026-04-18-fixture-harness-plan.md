# Fixture Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a fixture-driven pathology reproducer in `checkpoint-collector` that resets a seeded Postgres fixture database, drives concurrent HTTP traffic against an externally started demo app, and asserts that the bad `missing-index` query plan appears in both `EXPLAIN` and ClickHouse.

**Architecture:** The implementation keeps the fixture data and oracle docs under `fixtures/missing-index/`, adds a top-level `bin/fixture` CLI for `reset`, `drive`, `assert`, and `all`, and uses small Ruby support classes under `collector/lib/fixtures/` for manifest loading and command dispatch. Reset uses Postgres template databases (`fixture_01_tmpl` -> `fixture_01`) for fast rebuilds, `drive` records its execution window in `tmp/fixture-last-run.json`, and `assert` checks both the live Postgres plan and the collector’s ClickHouse output without changing compose or the collector pipeline.

**Tech Stack:** Ruby, Minitest, PostgreSQL 16, ClickHouse HTTP API, YAML manifests, SQL seed files, GNU Make for a manual smoke target.

---

## File Structure

- Create: `bin/fixture`
  Entrypoint that bootstraps Bundler from `collector/Gemfile`, parses CLI arguments, and dispatches verbs.
- Create: `collector/lib/fixtures/manifest.rb`
  Loads `fixtures/<name>/manifest.yml`, validates required keys, and exposes defaults used by `reset`, `drive`, and `assert`.
- Create: `collector/lib/fixtures/command.rb`
  Parses verbs/flags, resolves fixture script files, and runs `reset`, `drive`, `assert`, or `all` in order.
- Create: `collector/test/fixtures/fixture_manifest_test.rb`
  Covers manifest loading and validation failures.
- Create: `collector/test/fixtures/fixture_command_test.rb`
  Covers command parsing and `all` dispatch ordering.
- Create: `collector/test/fixtures/missing_index_reset_test.rb`
  Covers template rebuild logic, reset SQL ordering, and schema guarantees.
- Create: `collector/test/fixtures/missing_index_drive_test.rb`
  Covers `/up` polling, concurrent request driving, and `tmp/fixture-last-run.json`.
- Create: `collector/test/fixtures/missing_index_assert_test.rb`
  Covers `EXPLAIN` root-node validation and ClickHouse polling thresholds.
- Create: `collector/test/fixtures/fixture_smoke_target_test.rb`
  Covers the manual `make fixture-smoke` entrypoint.
- Create: `fixtures/missing-index/manifest.yml`
  Fixture metadata, workload defaults, DB name, health endpoint, and assertion signals.
- Create: `fixtures/missing-index/setup/01_schema.sql`
  Broken schema with `users`, `todos`, and a `todos(user_id)` index but no `todos(status)` index.
- Create: `fixtures/missing-index/setup/02_seed.sql`
  Seeds 1,000 users and 10,000,000 todos with roughly 0.2% `open` rows, then analyzes both tables.
- Create: `fixtures/missing-index/setup/reset.rb`
  Implements template creation, working DB recreation, and `pg_stat_statements_reset()`.
- Create: `fixtures/missing-index/load/drive.rb`
  Polls `BASE_URL/up`, drives concurrent HTTP requests, and persists last-run timing metadata.
- Create: `fixtures/missing-index/validate/assert.rb`
  Runs `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` and polls ClickHouse `query_events`.
- Create: `fixtures/missing-index/README.md`
  Documents oracle tags, what each fixes, and how `oracle/add-index` flips the explain assertion.
- Create: `Makefile`
  Adds `fixture-smoke` for the manual non-CI smoke run.
- Modify: `README.md`
  Add one short section pointing readers at `bin/fixture` and `fixtures/missing-index/README.md`.

## Task 1: Reset `db-specialist-demo` to the unoptimized baseline before writing fixture code

**Files:**
- Modify: `/home/bjw/db-specialist-demo` git refs only
- Test: `/home/bjw/db-specialist-demo` git history and tags

- [ ] **Step 1: Verify the current demo history contains the expected oracle commits**

Run:

```bash
git -C /home/bjw/db-specialist-demo log --oneline --decorate --graph --max-count=12
git -C /home/bjw/db-specialist-demo show --stat --oneline 4e68f5f c2bcc5f c2fb3d5 ab679e7
```

Expected: the log shows `rewrite_like`, `add_index`, and `rewrite_count` after `ab679e7`, and each SHA resolves successfully.

- [ ] **Step 2: Tag the oracle commits so the fixes remain available after the reset**

Run:

```bash
git -C /home/bjw/db-specialist-demo tag oracle/rewrite-like 4e68f5f
git -C /home/bjw/db-specialist-demo tag oracle/add-index c2bcc5f
git -C /home/bjw/db-specialist-demo tag oracle/rewrite-count c2fb3d5
```

Expected: each tag command exits 0.

- [ ] **Step 3: Verify the tags resolve to the intended commits**

Run:

```bash
git -C /home/bjw/db-specialist-demo show-ref --tags oracle/rewrite-like oracle/add-index oracle/rewrite-count
```

Expected: three tag refs appear, each pointing at the expected oracle commit.

- [ ] **Step 4: Hard-reset `master` to the single-commit MVP state and force-push**

Run:

```bash
git -C /home/bjw/db-specialist-demo checkout master
git -C /home/bjw/db-specialist-demo reset --hard ab679e7
git -C /home/bjw/db-specialist-demo push --force origin master
```

Expected: `master` now points at `ab679e7`, and the force-push completes without errors.

- [ ] **Step 5: Verify the demo repo is clean and no fix commit remains on `master`**

Run:

```bash
git -C /home/bjw/db-specialist-demo status --short --branch
git -C /home/bjw/db-specialist-demo log --oneline origin/master..master
git -C /home/bjw/db-specialist-demo tag --list 'oracle/*'
```

Expected: clean working tree, no commits ahead of `origin/master`, and all three `oracle/*` tags listed.

## Task 2: Add the shared fixture CLI and manifest loader

**Files:**
- Create: `bin/fixture`
- Create: `collector/lib/fixtures/manifest.rb`
- Create: `collector/lib/fixtures/command.rb`
- Create: `collector/test/fixtures/fixture_manifest_test.rb`
- Create: `collector/test/fixtures/fixture_command_test.rb`

- [ ] **Step 1: Write the failing manifest-loader and command-dispatch tests**

```ruby
# collector/test/fixtures/fixture_manifest_test.rb
require "minitest/autorun"
require "fileutils"
require "tmpdir"
require_relative "../../lib/fixtures/manifest"

class FixtureManifestTest < Minitest::Test
  def test_loads_missing_index_manifest
    Dir.mktmpdir do |dir|
      fixture_dir = File.join(dir, "missing-index")
      FileUtils.mkdir_p(fixture_dir)
      File.write(File.join(fixture_dir, "manifest.yml"), <<~YAML)
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
            query: SELECT 1
          clickhouse:
            statement_contains: todos.status
            min_call_count: 500
      YAML

      manifest = Fixtures::Manifest.load("missing-index", root: dir)

      assert_equal "missing-index", manifest.name
      assert_equal "fixture_01", manifest.db_name
      assert_equal "/up", manifest.health_endpoint
      assert_equal "GET", manifest.request_method
      assert_equal "/todos/status?status=open", manifest.request_path
      assert_equal "Seq Scan", manifest.explain_root_node_kind
    end
  end

  def test_raises_for_unknown_fixture
    Dir.mktmpdir do |dir|
      error = assert_raises(RuntimeError) { Fixtures::Manifest.load("nope", root: dir) }

      assert_includes error.message, "Unknown fixture"
    end
  end
end

# collector/test/fixtures/fixture_command_test.rb
require "minitest/autorun"
require "stringio"
require_relative "../../lib/fixtures/command"

class FixtureCommandTest < Minitest::Test
  def test_all_runs_reset_drive_and_assert_in_order
    events = []
    fake_manifest = Struct.new(:seconds, :concurrency, :rate).new(60, 16, "unlimited")
    registry = {
      ["missing-index", "reset"] => ->(**) { events << :reset },
      ["missing-index", "drive"] => ->(**) { events << :drive },
      ["missing-index", "assert"] => ->(**) { events << :assert },
    }

    Fixtures::Command.new(
      argv: ["missing-index", "all", "--seconds", "15", "--base-url", "http://localhost:3000"],
      registry: registry,
      manifest_loader: Class.new { define_singleton_method(:load) { |_| fake_manifest } },
      stdout: StringIO.new,
      stderr: StringIO.new,
    ).run

    assert_equal [:reset, :drive, :assert], events
  end

  def test_invalid_verb_prints_usage_and_returns_non_zero
    stdout = StringIO.new
    stderr = StringIO.new

    exit_code = Fixtures::Command.new(
      argv: ["missing-index", "explode"],
      registry: {},
      manifest_loader: Class.new { define_singleton_method(:load) { |_| Struct.new(:seconds, :concurrency, :rate).new(60, 16, "unlimited") } },
      stdout: stdout,
      stderr: stderr,
    ).run

    assert_equal 1, exit_code
    assert_includes stderr.string, "Usage:"
  end
end
```

- [ ] **Step 2: Run the tests to confirm they fail before implementation**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby collector/test/fixtures/fixture_manifest_test.rb
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby collector/test/fixtures/fixture_command_test.rb
```

Expected: FAIL because `Fixtures::Manifest` and `Fixtures::Command` do not exist yet.

- [ ] **Step 3: Implement the manifest loader, dispatcher, and executable entrypoint**

```ruby
# bin/fixture
#!/usr/bin/env ruby
# ABOUTME: Runs fixture reset, traffic drive, and validation commands for pathology reproducers.
# ABOUTME: Loads fixture metadata from the repo and dispatches to fixture-specific Ruby code.
ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../collector/Gemfile", __dir__)
require "bundler/setup"
require_relative "../collector/lib/fixtures/command"

exit Fixtures::Command.new(argv: ARGV, stdout: $stdout, stderr: $stderr).run
```

```ruby
# collector/lib/fixtures/manifest.rb
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

```ruby
# collector/lib/fixtures/command.rb
# ABOUTME: Parses `bin/fixture` arguments and dispatches work to fixture-specific classes.
# ABOUTME: Keeps the top-level CLI stable while fixture implementations live under `fixtures/`.
require "optparse"
require_relative "manifest"

module Fixtures
  class Command
    USAGE = "Usage: bin/fixture <name> <reset|drive|assert|all> [flags]".freeze

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
      return usage_error if fixture_name.nil? || verb.nil?

      manifest = @manifest_loader.load(fixture_name)
      options = parse_flags(manifest: manifest, verb: verb)

      if verb == "all"
        %w[reset drive assert].each { |step| @registry.fetch([fixture_name, step]).call(manifest: manifest, options: options) }
      else
        handler = @registry[[fixture_name, verb]]
        return usage_error if handler.nil?

        handler.call(manifest: manifest, options: options)
      end

      0
    rescue OptionParser::ParseError, RuntimeError => error
      @stderr.puts(error.message)
      usage_error
    end

    private

    def usage_error
      @stderr.puts(USAGE)
      1
    end

    def default_registry
      require File.expand_path("../../../fixtures/missing-index/setup/reset", __dir__)
      require File.expand_path("../../../fixtures/missing-index/load/drive", __dir__)
      require File.expand_path("../../../fixtures/missing-index/validate/assert", __dir__)

      {
        ["missing-index", "reset"] => ->(manifest:, options:) { Fixtures::MissingIndex::Reset.new(manifest: manifest, options: options).run },
        ["missing-index", "drive"] => ->(manifest:, options:) { Fixtures::MissingIndex::Drive.new(manifest: manifest, options: options).run },
        ["missing-index", "assert"] => ->(manifest:, options:) { Fixtures::MissingIndex::Assert.new(manifest: manifest, options: options, stdout: @stdout).run },
      }
    end

    def parse_flags(manifest:, verb:)
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
        parser.on("--rate VALUE") { |value| options[:rate] = value == "unlimited" ? "unlimited" : Integer(value) }
        parser.on("--base-url URL") { |value| options[:base_url] = value }
        parser.on("--timeout-seconds N", Integer) { |value| options[:timeout_seconds] = value }
      end.parse!(@argv)

      options
    end
  end
end
```

- [ ] **Step 4: Run the tests again to verify the CLI skeleton passes**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby collector/test/fixtures/fixture_manifest_test.rb
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby collector/test/fixtures/fixture_command_test.rb
```

Expected: PASS.

- [ ] **Step 5: Add `tmp/` to `.gitignore`**

```bash
echo "tmp/" >> .gitignore
git add .gitignore
```

`drive.rb` writes `tmp/fixture-last-run.json` on every run. Without this entry the file shows as untracked after each drive.

- [ ] **Step 6: Commit the CLI scaffold**

```bash
git add bin/fixture collector/lib/fixtures/manifest.rb collector/lib/fixtures/command.rb collector/test/fixtures/fixture_manifest_test.rb collector/test/fixtures/fixture_command_test.rb .gitignore
git commit -m "feat: add fixture command scaffold"
```

## Task 3: Implement fast template-based reset for `fixture_01`

**Files:**
- Create: `fixtures/missing-index/manifest.yml`
- Create: `fixtures/missing-index/setup/01_schema.sql`
- Create: `fixtures/missing-index/setup/02_seed.sql`
- Create: `fixtures/missing-index/setup/reset.rb`
- Create: `collector/test/fixtures/missing_index_reset_test.rb`

- [ ] **Step 1: Write the failing reset tests**

```ruby
# collector/test/fixtures/missing_index_reset_test.rb
require "minitest/autorun"
require_relative "../../../fixtures/missing-index/setup/reset"
require_relative "../../lib/fixtures/manifest"

class MissingIndexResetTest < Minitest::Test
  def test_rebuild_template_drops_existing_template_and_working_database
    statements = []
    manifest = Fixtures::Manifest.load("missing-index")

    Fixtures::MissingIndex::Reset.new(
      manifest: manifest,
      options: { admin_url: "postgresql://localhost/postgres", rebuild_template: true },
      pg: FakePg.new(FakeConnection.new(statements, exists: false)),
    ).run

    assert_includes statements, 'DROP DATABASE IF EXISTS "fixture_01"'
    assert_includes statements, 'DROP DATABASE IF EXISTS "fixture_01_tmpl"'
    assert_includes statements, 'CREATE DATABASE "fixture_01_tmpl"'
    assert_includes statements, 'CREATE DATABASE "fixture_01" TEMPLATE "fixture_01_tmpl"'
    assert_includes statements, "SELECT pg_stat_statements_reset()"
  end

  def test_template_exists_skips_build
    statements = []
    manifest = Fixtures::Manifest.load("missing-index")

    Fixtures::MissingIndex::Reset.new(
      manifest: manifest,
      options: { admin_url: "postgresql://localhost/postgres", rebuild_template: false },
      pg: FakePg.new(FakeConnection.new(statements, exists: true)),
    ).run

    refute_includes statements, 'CREATE DATABASE "fixture_01_tmpl"'
    assert_includes statements, 'CREATE DATABASE "fixture_01" TEMPLATE "fixture_01_tmpl"'
  end

  def test_schema_file_creates_user_id_index_and_no_status_index
    sql = File.read(File.expand_path("../../../fixtures/missing-index/setup/01_schema.sql", __dir__))

    assert_includes sql, "CREATE INDEX index_todos_on_user_id"
    refute_match(/CREATE INDEX .*status/i, sql)
    refute_includes sql, "index_todos_on_status"
  end

  # Returns the same connection for every connect() call so load_sql's additional
  # connects don't exhaust a finite pool.
  class FakePg
    def initialize(connection)
      @connection = connection
    end

    def connect(*) = @connection
  end

  FakeResult = Struct.new(:ntuples)

  class FakeConnection
    def initialize(statements, exists:)
      @statements = statements
      @exists = exists
    end

    def exec(sql)
      @statements << sql.strip
      []
    end

    # Used by database_exists? — returns ntuples=1 (exists) or ntuples=0 (absent).
    def exec_params(sql, _params)
      @statements << sql.strip
      FakeResult.new(@exists ? 1 : 0)
    end

    def close; end
  end
end
```

- [ ] **Step 2: Run the reset tests to confirm they fail**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby collector/test/fixtures/missing_index_reset_test.rb
```

Expected: FAIL because the fixture manifest, SQL files, and reset implementation do not exist yet.

- [ ] **Step 3: Add the fixture manifest and SQL seeds**

```yaml
# fixtures/missing-index/manifest.yml
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

```sql
-- fixtures/missing-index/setup/01_schema.sql
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

```sql
-- fixtures/missing-index/setup/02_seed.sql
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

- [ ] **Step 4: Implement template build and working DB recreation**

```ruby
# fixtures/missing-index/setup/reset.rb
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
        connection.exec(File.read(File.expand_path(name, File.expand_path("../", __FILE__))))
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

- [ ] **Step 5: Run the reset test and a first real template build**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby collector/test/fixtures/missing_index_reset_test.rb
bin/fixture missing-index reset --rebuild-template
```

Expected: the Ruby test passes, then the real reset command builds `fixture_01_tmpl`, clones `fixture_01`, and exits 0.

- [ ] **Step 6: Run a second reset to confirm the template path is fast**

Run:

```bash
time bin/fixture missing-index reset
```

Expected: command exits 0 and finishes much faster than the first `--rebuild-template` run because it reuses `fixture_01_tmpl`.

- [ ] **Step 7: Commit the reset implementation**

```bash
git add fixtures/missing-index/manifest.yml fixtures/missing-index/setup/01_schema.sql fixtures/missing-index/setup/02_seed.sql fixtures/missing-index/setup/reset.rb collector/test/fixtures/missing_index_reset_test.rb
git commit -m "feat: add fixture database reset"
```

## Task 4: Implement concurrent traffic driving against the external demo app

**Files:**
- Create: `fixtures/missing-index/load/drive.rb`
- Create: `collector/test/fixtures/missing_index_drive_test.rb`

- [ ] **Step 1: Write the failing drive tests**

```ruby
# collector/test/fixtures/missing_index_drive_test.rb
require "json"
require "minitest/autorun"
require "tmpdir"
require "webrick"
require_relative "../../../fixtures/missing-index/load/drive"
require_relative "../../lib/fixtures/manifest"

class MissingIndexDriveTest < Minitest::Test
  def test_waits_for_up_endpoint_then_records_last_run_window
    requests = Queue.new
    health_checks = 0
    server = WEBrick::HTTPServer.new(Port: 0, Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
    server.mount_proc("/up") do |_req, res|
      health_checks += 1
      res.status = health_checks < 3 ? 503 : 200
      res.body = "ok"
    end
    server.mount_proc("/todos/status") do |req, res|
      requests << req.query["status"]
      res.status = 200
      res.body = "ok"
    end
    Thread.new { server.start }

    manifest = Fixtures::Manifest.load("missing-index")
    Dir.mktmpdir do |dir|
      Fixtures::MissingIndex::Drive.new(
        manifest: manifest,
        options: { base_url: "http://127.0.0.1:#{server.config[:Port]}", seconds: 1, concurrency: 2, rate: "unlimited", output_dir: dir },
      ).run

      payload = JSON.parse(File.read(File.join(dir, "fixture-last-run.json")))
      assert_operator payload.fetch("request_count"), :>, 0
      assert payload.fetch("start_ts") <= payload.fetch("end_ts")
      assert_equal "open", requests.pop
    end
  ensure
    server&.shutdown
  end
end
```

- [ ] **Step 2: Run the drive test to confirm it fails**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby collector/test/fixtures/missing_index_drive_test.rb
```

Expected: FAIL because the drive implementation does not exist yet.

- [ ] **Step 3: Implement the traffic driver**

```ruby
# fixtures/missing-index/load/drive.rb
# ABOUTME: Waits for the external demo app and drives concurrent requests against the missing-index endpoint.
# ABOUTME: Persists the last traffic window so fixture assertions can query ClickHouse for the same interval.
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
        @rate_limiters = Hash.new { |hash, key| hash[key] = RateLimiter.new(@options.fetch(:rate), clock: @clock, sleeper: @sleeper) }
      end

      def run
        wait_until_up!
        start_time = @clock.call
        finish_at = start_time + @options.fetch(:seconds)
        count = 0
        mutex = Mutex.new

        threads = Array.new(@options.fetch(:concurrency)) do
          Thread.new do
            while @clock.call < finish_at
              request_endpoint
              mutex.synchronize { count += 1 }
              @rate_limiters[Thread.current.object_id].wait_turn
            end
          end
        end
        threads.each(&:join)

        finish_time = @clock.call
        write_last_run(start_time:, finish_time:, request_count: count)
      end

      private

      def wait_until_up!
        deadline = Time.now + 120
        until healthy?
          raise "Timed out waiting for #{@options.fetch(:base_url)}#{@manifest.health_endpoint}" if Time.now >= deadline

          @sleeper.call(1)
        end
      end

      def healthy?
        response = Net::HTTP.get_response(URI.join(@options.fetch(:base_url), @manifest.health_endpoint))
        response.code.to_i == 200
      rescue Errno::ECONNREFUSED
        false
      end

      def request_endpoint
        Net::HTTP.get_response(URI.join(@options.fetch(:base_url), @manifest.request_path))
      end

      def write_last_run(start_time:, finish_time:, request_count:)
        output_dir = @options.fetch(:output_dir, File.expand_path("../../../tmp", __dir__))
        Dir.mkdir(output_dir) unless Dir.exist?(output_dir)
        File.write(
          File.join(output_dir, "fixture-last-run.json"),
          JSON.pretty_generate(
            start_ts: start_time.iso8601(3),
            end_ts: finish_time.iso8601(3),
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
        end

        def wait_turn
          return if @rate == "unlimited"

          now = @clock.call
          @next_allowed_at ||= now
          if @next_allowed_at > now
            @sleeper.call(@next_allowed_at - now)
          end
          @next_allowed_at = [@next_allowed_at, now].max + (1.0 / @rate)
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the drive test and one real traffic pass**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby collector/test/fixtures/missing_index_drive_test.rb
DATABASE_URL=postgres://postgres:postgres@localhost:5432/fixture_01 ~/db-specialist-demo/bin/rails server
bin/fixture missing-index drive --seconds 5 --concurrency 4
```

Expected: the Ruby test passes, the external demo app starts separately, and `bin/fixture ... drive` exits 0 after writing `tmp/fixture-last-run.json`.

- [ ] **Step 5: Commit the drive implementation**

```bash
git add fixtures/missing-index/load/drive.rb collector/test/fixtures/missing_index_drive_test.rb
git commit -m "feat: add fixture traffic driver"
```

## Task 5: Implement `EXPLAIN` and ClickHouse assertions

**Files:**
- Create: `fixtures/missing-index/validate/assert.rb`
- Create: `collector/test/fixtures/missing_index_assert_test.rb`

- [ ] **Step 1: Write the failing assertion tests**

```ruby
# collector/test/fixtures/missing_index_assert_test.rb
require "json"
require "minitest/autorun"
require "stringio"
require_relative "../../../fixtures/missing-index/validate/assert"
require_relative "../../lib/fixtures/manifest"

class MissingIndexAssertTest < Minitest::Test
  def test_passes_when_explain_root_is_seq_scan_and_clickhouse_threshold_is_met
    manifest = Fixtures::Manifest.load("missing-index")
    explain_rows = [{ "QUERY PLAN" => JSON.generate([{ "Plan" => { "Node Type" => "Seq Scan", "Relation Name" => "todos" } }]) }]
    snapshots = [
      { "calls" => "250", "mean_ms" => "41.0" },
      { "calls" => "600", "mean_ms" => "42.3" },
    ]
    stdout = StringIO.new

    Fixtures::MissingIndex::Assert.new(
      manifest: manifest,
      options: { clickhouse_url: "http://clickhouse:8123", timeout_seconds: 20, last_run_path: fixture_last_run_path },
      stdout: stdout,
      pg: FakePg.new(explain_rows),
      clickhouse_query: ->(*) { snapshots.shift },
      sleeper: ->(*) {},
    ).run

    assert_includes stdout.string, "PASS: explain"
    assert_includes stdout.string, "PASS: clickhouse"
  end

  def test_fails_when_plan_flips_to_index_scan
    manifest = Fixtures::Manifest.load("missing-index")
    explain_rows = [{ "QUERY PLAN" => JSON.generate([{ "Plan" => { "Node Type" => "Index Scan", "Relation Name" => "todos" } }]) }]

    error = assert_raises(RuntimeError) do
      Fixtures::MissingIndex::Assert.new(
        manifest: manifest,
        options: { clickhouse_url: "http://clickhouse:8123", timeout_seconds: 1, last_run_path: fixture_last_run_path },
        stdout: StringIO.new,
        pg: FakePg.new(explain_rows),
        clickhouse_query: ->(*) { { "calls" => "600", "mean_ms" => "2.3" } },
        sleeper: ->(*) {},
      ).run
    end

    assert_includes error.message, "Expected Seq Scan"
  end

  def test_clickhouse_timeout_raises_with_call_count
    manifest = Fixtures::Manifest.load("missing-index")
    explain_rows = [{ "QUERY PLAN" => JSON.generate([{ "Plan" => { "Node Type" => "Seq Scan", "Relation Name" => "todos" } }]) }]

    error = assert_raises(RuntimeError) do
      Fixtures::MissingIndex::Assert.new(
        manifest: manifest,
        options: { clickhouse_url: "http://clickhouse:8123", timeout_seconds: 0, last_run_path: fixture_last_run_path },
        stdout: StringIO.new,
        pg: FakePg.new(explain_rows),
        clickhouse_query: ->(*) { { "calls" => "10", "mean_ms" => "0.0" } },
        sleeper: ->(*) {},
      ).run
    end

    assert_includes error.message, "10"
  end

  def test_missing_last_run_file_raises_clear_error
    manifest = Fixtures::Manifest.load("missing-index")

    error = assert_raises(RuntimeError) do
      Fixtures::MissingIndex::Assert.new(
        manifest: manifest,
        options: { clickhouse_url: "http://clickhouse:8123", timeout_seconds: 1, last_run_path: "/nonexistent/fixture-last-run.json" },
        stdout: StringIO.new,
        pg: FakePg.new([]),
        clickhouse_query: ->(*) { {} },
        sleeper: ->(*) {},
      ).run
    end

    assert_includes error.message, "fixture-last-run.json"
  end

  private

  def fixture_last_run_path
    path = File.expand_path("../../../tmp/fixture-last-run.json", __dir__)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(start_ts: "2026-04-18T12:00:00.000Z", end_ts: "2026-04-18T12:01:00.000Z", request_count: 100))
    path
  end

  class FakePg
    def initialize(rows)
      @rows = rows
    end

    def connect(*)
      FakeConnection.new(@rows)
    end
  end

  class FakeConnection
    def initialize(rows)
      @rows = rows
    end

    def exec(*)
      @rows
    end

    def close; end
  end
end
```

- [ ] **Step 2: Run the assertion test to confirm it fails**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby collector/test/fixtures/missing_index_assert_test.rb
```

Expected: FAIL because the assertion implementation does not exist yet.

- [ ] **Step 3: Implement `EXPLAIN` validation and ClickHouse polling**

```ruby
# fixtures/missing-index/validate/assert.rb
# ABOUTME: Verifies the fixture reproduces the bad query plan in Postgres and in ClickHouse query snapshots.
# ABOUTME: Reads the last traffic window from disk so ClickHouse polling matches the requests driven by the fixture.
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
        @stdout.puts("PASS: explain (#{plan.fetch("Node Type")} on #{plan.fetch("Relation Name")}, root node confirmed)")
        @stdout.puts("PASS: clickhouse (#{clickhouse.fetch("calls")} calls; mean #{clickhouse.fetch("mean_ms")}ms)")
      end

      private

      def explain_root_plan
        connection = @pg.connect(database_url(@manifest.db_name))
        rows = connection.exec(%(EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{@manifest.explain_query}))
        payload = JSON.parse(rows.first.fetch("QUERY PLAN"))
        payload.fetch(0).fetch("Plan")
      ensure
        connection&.close
      end

      def verify_plan!(plan)
        unless plan.fetch("Node Type") == @manifest.explain_root_node_kind && plan.fetch("Relation Name") == @manifest.explain_root_relation
          raise "Expected #{@manifest.explain_root_node_kind} on #{@manifest.explain_root_relation}, got #{plan.fetch("Node Type")} on #{plan.fetch("Relation Name")}"
        end
      end

      def wait_for_clickhouse!
        last_run_path = @options.fetch(:last_run_path, File.expand_path("../../../tmp/fixture-last-run.json", __dir__))
        window = begin
          JSON.parse(File.read(last_run_path))
        rescue Errno::ENOENT
          raise "Run 'bin/fixture #{@manifest.name} drive' first — fixture-last-run.json not found: #{last_run_path}"
        end
        deadline = Time.now + @options.fetch(:timeout_seconds)

        loop do
          snapshot = @clickhouse_query.call(window)
          return snapshot if snapshot.fetch("calls").to_i >= @manifest.clickhouse_min_call_count

          raise "ClickHouse saw only #{snapshot.fetch("calls")} calls before timeout" if Time.now >= deadline

          @sleeper.call(10)
        end
      end

      def query_clickhouse(window)
        sql = <<~SQL
          SELECT
            toString(coalesce(sum(total_exec_count), 0)) AS calls,
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
    end
  end
end
```

- [ ] **Step 4: Run the assertion test, then exercise the real broken-state fixture**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby collector/test/fixtures/missing_index_assert_test.rb
bin/fixture missing-index assert --timeout-seconds 180
```

Expected: the test passes, then the real assertion prints `PASS: explain` and `PASS: clickhouse`.

- [ ] **Step 5: Prove the fixture distinguishes broken from fixed by applying `oracle/add-index`**

Run:

```bash
git -C /home/bjw/db-specialist-demo checkout oracle/add-index
DATABASE_URL=postgres://postgres:postgres@localhost:5432/fixture_01 ~/db-specialist-demo/bin/rails server
bin/fixture missing-index assert --timeout-seconds 180
git -C /home/bjw/db-specialist-demo checkout master
```

Expected: `bin/fixture ... assert` fails with an `Index Scan` / expected `Seq Scan` mismatch while the oracle tag is checked out.

- [ ] **Step 6: Commit the assertion implementation**

```bash
git add fixtures/missing-index/validate/assert.rb collector/test/fixtures/missing_index_assert_test.rb
git commit -m "feat: add fixture assertions"
```

## Task 6: Add oracle documentation and the manual smoke target

**Files:**
- Create: `fixtures/missing-index/README.md`
- Create: `Makefile`
- Modify: `README.md`
- Create: `collector/test/fixtures/fixture_smoke_target_test.rb`

- [ ] **Step 1: Write the failing smoke-target test**

```ruby
# collector/test/fixtures/fixture_smoke_target_test.rb
require "minitest/autorun"

class FixtureSmokeTargetTest < Minitest::Test
  def test_makefile_exposes_fixture_smoke_target
    makefile = File.read(File.expand_path("../../../Makefile", __dir__))

    assert_match(/^fixture-smoke:/, makefile)
    assert_includes makefile, "bin/fixture missing-index all"
  end
end
```

- [ ] **Step 2: Run the smoke-target test to confirm it fails**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby collector/test/fixtures/fixture_smoke_target_test.rb
```

Expected: FAIL because `Makefile` does not exist yet.

- [ ] **Step 3: Add oracle docs, `Makefile`, and the short root README note**

````markdown
# fixtures/missing-index/README.md

This fixture reproduces the broken `todos.status` plan against the external demo app.

## Oracle tags

- `oracle/rewrite-like` rewrites the text search path in the demo repo.
- `oracle/add-index` adds the missing `todos(status)` index and flips the root node from `Seq Scan` to `Index Scan`.
- `oracle/rewrite-count` changes the stats query path.

## Demo app startup

Start the collector stack in `checkpoint-collector`, then start the demo app separately:

```bash
DATABASE_URL=postgres://postgres:postgres@localhost:5432/fixture_01 ~/db-specialist-demo/bin/rails server
```

## Commands

```bash
bin/fixture missing-index reset --rebuild-template
bin/fixture missing-index drive
bin/fixture missing-index assert
bin/fixture missing-index all
```

## Oracle verification

```bash
git -C ~/db-specialist-demo checkout oracle/add-index
bin/fixture missing-index assert --timeout-seconds 180
git -C ~/db-specialist-demo checkout master
```

The assertion should fail because the root node becomes `Index Scan`.
````

```make
# Makefile
fixture-smoke:
	bin/fixture missing-index all
```

````markdown
## Fixture harness

Use `bin/fixture missing-index all` to reproduce the missing-index pathology against an externally started `db-specialist-demo` app. Oracle tag details and the add-index verification flow live in `fixtures/missing-index/README.md`.
````

- [ ] **Step 4: Run the smoke-target test and a manual smoke pass**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby collector/test/fixtures/fixture_smoke_target_test.rb
make fixture-smoke
```

Expected: the test passes, and `make fixture-smoke` exits 0 once Postgres, ClickHouse, the collector, and the external demo app are all running.

- [ ] **Step 5: Commit the docs and smoke target**

```bash
git add fixtures/missing-index/README.md Makefile README.md collector/test/fixtures/fixture_smoke_target_test.rb
git commit -m "docs: add fixture oracle guide"
```

## Task 7: Run the final verification set and record the outcome

**Files:**
- Test: `collector/test/fixtures/fixture_manifest_test.rb`
- Test: `collector/test/fixtures/fixture_command_test.rb`
- Test: `collector/test/fixtures/missing_index_reset_test.rb`
- Test: `collector/test/fixtures/missing_index_drive_test.rb`
- Test: `collector/test/fixtures/missing_index_assert_test.rb`
- Test: `collector/test/fixtures/fixture_smoke_target_test.rb`
- Test: `load/test/harness_test.rb`
- Test: `tests/smoke/test_collector_pipeline.py`

- [ ] **Step 1: Run the fixture Ruby unit test set**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby collector/test/fixtures/fixture_manifest_test.rb
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby collector/test/fixtures/fixture_command_test.rb
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby collector/test/fixtures/missing_index_reset_test.rb
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby collector/test/fixtures/missing_index_drive_test.rb
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby collector/test/fixtures/missing_index_assert_test.rb
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby collector/test/fixtures/fixture_smoke_target_test.rb
```

Expected: PASS.

- [ ] **Step 2: Re-run the preserved load harness test unchanged**

Run:

```bash
ruby load/test/harness_test.rb
```

Expected: PASS with no changes required to `load/harness.rb`.

- [ ] **Step 3: Re-run the collector smoke test**

Run:

```bash
python3 -m pytest tests/smoke/test_collector_pipeline.py -v
```

Expected: PASS.

- [ ] **Step 4: Re-run the full fixture flow from a clean reset**

Run:

```bash
bin/fixture missing-index all --rebuild-template --timeout-seconds 180
```

Expected: the command builds the template if needed, recreates `fixture_01`, drives traffic, prints both PASS lines, and exits 0.

- [ ] **Step 5: Record the result in `JOURNAL.md` and commit the final verification state**

```markdown
## 2026-04-18

- Added the first fixture harness at `bin/fixture` with the `missing-index` pathology under `fixtures/missing-index/`.
- Reset `db-specialist-demo` to `ab679e7` and preserved the three fix commits as `oracle/rewrite-like`, `oracle/add-index`, and `oracle/rewrite-count`.
- Verified the wedge end to end: `bin/fixture missing-index all` passes on the broken demo app, and `oracle/add-index` flips the explain assertion to fail.
```

```bash
git add JOURNAL.md
git commit -m "test: verify fixture harness end to end"
```

## GSTACK REVIEW REPORT

| Review | Trigger | Runs | Status | Findings |
|--------|---------|------|--------|----------|
| Eng Review | `/plan-eng-review` | 1 | DONE | 5 issues found and fixed (see below) |

**Issues resolved during review:**

| Severity | Confidence | Location | Issue | Resolution |
|----------|-----------|----------|-------|------------|
| P1 | 9/10 | `reset.rb:drop_database` | `pg_terminate_backend` used string interpolation for `datname` | Changed to `exec_params` with `$1` parameter |
| P1 | 9/10 | `missing_index_reset_test.rb` | `FakeConnection` missing `exec_params`; `FakePg` exhausted connections on `load_sql` calls | Refactored to single shared connection + `FakeResult` struct |
| P1 | 9/10 | `missing_index_assert_test.rb` | `fixture_last_run_path` used `../../../../tmp` (above repo root) | Fixed to `../../../tmp` + `FileUtils.mkdir_p` |
| P2 | 9/10 | `.gitignore` | `tmp/` missing; `fixture-last-run.json` shows as untracked after every drive run | Added `tmp/` to `.gitignore` in Task 2 Step 5 |
| P2 | 8/10 | `missing_index_assert_test.rb` | Missing tests for ClickHouse timeout, missing last-run file, and template-exists skip path | Added three tests; `assert.rb` wraps `Errno::ENOENT` as `RuntimeError` with actionable message |

**VERDICT:** APPROVED — all issues resolved inline. Plan is ready for implementation.

## Self-Review

- Spec coverage:
  Task 1 covers the required `db-specialist-demo` reset, oracle tags, hard reset to `ab679e7`, and force-push before fixture code.
  Task 3 covers opaque database names, explicit broken schema creation, 10M-row seeding, template DB reset, and `pg_stat_statements_reset()`.
  Task 4 covers the external demo app, `BASE_URL/up` polling, concurrent HTTP traffic, and `tmp/fixture-last-run.json`.
  Task 5 covers `EXPLAIN` root-node validation, ClickHouse polling against `query_events`, the `oracle/add-index` flip check, and the “no collector changes needed” decision.
  Task 6 covers oracle documentation in `fixtures/missing-index/README.md` and the manual `make fixture-smoke` target.
  Task 7 covers preserving `load/harness.rb` and `load/test/harness_test.rb`, re-running `tests/smoke/`, and recording verification evidence in `JOURNAL.md`.
- Placeholder scan: no `TODO`, `TBD`, or “similar to Task N” placeholders remain.
- Type consistency: all tasks use the same fixture name (`missing-index`), DB names (`fixture_01`, `fixture_01_tmpl`), oracle tags, command verbs, and last-run file path.

## GSTACK REVIEW REPORT (Implementation Review — 2026-04-19)

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 2 | DONE_WITH_CONCERNS (fixed inline) | 4 issues, all resolved |
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Codex Review | `/codex review` | Independent 2nd opinion | 1 | Used as outside voice | 1 actionable finding incorporated |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | — |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

### Issues Found and Resolved

| Severity | Confidence | Location | Finding | Resolution |
|----------|------------|----------|---------|------------|
| P1 | 10/10 | `fixture_command_test.rb:with_require_guard` | Test isolation bug: `remove_const :Reset` destroys constant between test files; suite fails non-deterministically (confirmed with seed 12215) | Save+restore original const with `$VERBOSE=nil` suppression |
| P1 | 9/10 | `assert.rb:query_clickhouse` | `sum(total_exec_count)` double-counts cumulative pg_stat_statements snapshots; after reset, actual calls ≠ SUM across intervals | Changed to `max(total_exec_count)` |
| P2 | 9/10 | `drive.rb:RateLimiter` | `wait_turn` timing algorithm not unit tested; only tested via stub | Added 2 direct unit tests (finite rate + unlimited) |
| P3 | 9/10 | `reset.rb:load_sql` | `File.expand_path(name, File.expand_path(__dir__))` — inner expand is redundant | Simplified to `File.expand_path(name, __dir__)` |

### Codex Outside Voice — Cross-Model Tensions

**Resolved:** ClickHouse SUM → MAX (codex correct, incorporated).

**Disagree:** Codex flagged HTTP-driving the external app as “unnecessary complexity” vs direct SQL. Intentional — the fixture exists to capture ORM-generated query patterns through a real app stack, not just raw SQL. HTTP approach stays.

**Known limitation (not fixing):** 90-second ClickHouse wait is timing-based, not barrier-based. Acceptable for an MVP dev tool. `tmp/fixture-last-run.json` is shared globally; parallel runs would stomp each other. Both are scoped to “first fixture” MVP and noted for future work.

**VERDICT:** DONE — all P1/P2 issues resolved. Suite clean across random seeds. 23 runs, 94 assertions, 0 failures.
