# PlanetScale Remote Soak Walkthrough

*2026-04-26T19:39:54Z by Showboat 0.6.1*
<!-- showboat-id: 7d2f9a7e-d7ee-407e-ae4c-6c7203fd0404 -->

This walkthrough follows the branch in the order a PlanetScale soak run actually uses it: operator entrypoint, load runner handoff, Rails reset/reseed, workload preflight and invariants, collector stats polling, and finally the docs/future-work surface. The code snippets are captured with executable commands so the walkthrough doubles as a lightweight proof document.

Linear plan: 1. Start at `make load-soak-planetscale`, because it is the operator-safe entrypoint. 2. Follow `bin/load soak` through the load client timeout behavior needed for PlanetScale. 3. Enter the Rails adapter reset path and explain how `BENCH_ADAPTER_RESET_STRATEGY=remote` changes reset semantics. 4. Explain the workload-specific verifier and invariant sampler changes discovered during live checkpoints. 5. Explain collector stats-only mode, which makes remote Postgres usable without Docker log files. 6. Close with the tested contracts and documented fast follows.

The operator entrypoint is intentionally small. It refuses to run without both app traffic and admin/stat connection URLs, then forces the remote reset strategy and the PlanetScale-specific soak flags that live verification proved necessary: warning-only invariants for planner-stat drift and a longer startup grace for Rails boot after reseed.

```bash
sed -n '1,45p' Makefile
```

```output
# ABOUTME: Defines local verification and benchmark operator shortcuts.
# ABOUTME: Keeps destructive load commands explicit about their required environment.
.PHONY: load-smoke verify-fixture load-soak test test-load test-adapters test-adapters-fixture-integration test-adapters-demo-integration test-adapters-integration test-workloads load-soak-planetscale

test: test-load test-adapters test-workloads

test-load:
	BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby -e 'Dir["load/test/*_test.rb"].sort.each { |path| load path }'

test-adapters:
	BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby -e 'Dir["adapters/rails/test/*_test.rb"].sort.each { |path| load path }'

test-adapters-fixture-integration:
	RUN_RAILS_INTEGRATION=1 BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby adapters/rails/test/integration_test.rb --name test_prepare_migrate_load_start_and_stop_against_fixture_app

test-adapters-demo-integration:
	DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo BENCH_ADAPTER_PG_ADMIN_URL=postgres://postgres:postgres@localhost:5432/postgres RUN_DB_SPECIALIST_DEMO_INTEGRATION=1 DB_SPECIALIST_DEMO_PATH=/home/bjw/db-specialist-demo BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby adapters/rails/test/integration_test.rb --name test_real_db_specialist_demo_end_to_end

test-adapters-integration: test-adapters-fixture-integration test-adapters-demo-integration

test-workloads:
	BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby -e 'Dir["workloads/missing_index_todos/test/*_test.rb"].sort.each { |path| load path }'

load-smoke:
	DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo BENCH_ADAPTER_PG_ADMIN_URL=postgres://postgres:postgres@localhost:5432/postgres bin/load run --workload missing-index-todos --adapter adapters/rails/bin/bench-adapter --app-root /home/bjw/db-specialist-demo

verify-fixture:
	DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo BENCH_ADAPTER_PG_ADMIN_URL=postgres://postgres:postgres@localhost:5432/postgres bin/load verify-fixture --workload missing-index-todos --adapter adapters/rails/bin/bench-adapter --app-root /home/bjw/db-specialist-demo

load-soak:
	DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo BENCH_ADAPTER_PG_ADMIN_URL=postgres://postgres:postgres@localhost:5432/postgres bin/load soak --workload missing-index-todos --adapter adapters/rails/bin/bench-adapter --app-root /home/bjw/db-specialist-demo

load-soak-planetscale:
	@test -n "$$DATABASE_URL" || (echo "DATABASE_URL is required" >&2; exit 1)
	@test -n "$$BENCH_ADAPTER_PG_ADMIN_URL" || (echo "BENCH_ADAPTER_PG_ADMIN_URL is required" >&2; exit 1)
	BENCH_ADAPTER_RESET_STRATEGY=remote bin/load soak --workload missing-index-todos --invariants warn --startup-grace-seconds 60 --adapter adapters/rails/bin/bench-adapter --app-root /home/bjw/db-specialist-demo
```

The README tells operators the same thing in prose: this targets an existing PlanetScale branch, reset/reseed is destructive, `pg_stat_statements` must be enabled on the branch, and the local collector should run in stats-only mode because PlanetScale does not expose the Docker JSON log file.

```bash
sed -n '314,372p' README.md
```

````output

Reset and reseed the PlanetScale branch:

```bash
DATABASE_URL="$DATABASE_URL" \
BENCH_ADAPTER_PG_ADMIN_URL="$BENCH_ADAPTER_PG_ADMIN_URL" \
BENCH_ADAPTER_RESET_STRATEGY=remote \
adapters/rails/bin/bench-adapter --json reset-state \
  --app-root /home/bjw/db-specialist-demo \
  --workload missing-index-todos \
  --seed 42 \
  --env ROWS_PER_TABLE=100000 \
  --env OPEN_FRACTION=0.6 \
  --env USER_COUNT=100
```

Run soak:

```bash
DATABASE_URL="$DATABASE_URL" \
BENCH_ADAPTER_PG_ADMIN_URL="$BENCH_ADAPTER_PG_ADMIN_URL" \
make load-soak-planetscale
```

PlanetScale-backed Rails startup can take longer than the local Docker path
after reset/reseed. The `load-soak-planetscale` target uses
`--startup-grace-seconds 60` and `--invariants warn`, which records invariant
samples without aborting on PlanetScale planner-stat estimate drift.

Run the collector against PlanetScale in stats-only mode:

```bash
COLLECTOR_DISABLE_LOG_INGESTION=1 \
POSTGRES_URL="$POSTGRES_URL" \
CLICKHOUSE_URL=http://localhost:8123 \
BUNDLE_GEMFILE=collector/Gemfile \
bundle exec ruby collector/bin/collector
```

For a one-pass checkpoint, load the collector entrypoint explicitly:

```bash
COLLECTOR_DISABLE_LOG_INGESTION=1 \
POSTGRES_URL="$POSTGRES_URL" \
CLICKHOUSE_URL=http://localhost:8123 \
BUNDLE_GEMFILE=collector/Gemfile \
bundle exec ruby -e 'load "./collector/bin/collector"; CollectorRuntime.new(interval_seconds: 5, postgres_url: ENV.fetch("POSTGRES_URL"), clickhouse_url: ENV.fetch("CLICKHOUSE_URL")).run_once_pass'
```

Branch-per-run automation and PlanetScale Logs/Insights ingestion are future
work. The first PlanetScale implementation uses `pg_stat_statements` query
evidence.

## Manual Exploration

If `make load-smoke` times out or exits `3`, the fastest way to understand why
is to separate:

- database reset and seeding
````

The load client change is small but important for PlanetScale: callers can now choose a request timeout. Normal request paths still default to five seconds, while the fixture verifier below uses a longer timeout for slow preflight endpoints after reset.

```bash
sed -n '1,115p' load/lib/load/client.rb
```

```output
# ABOUTME: Issues HTTP requests against the application under test.
# ABOUTME: Wraps Net::HTTP with a base URL and simple request helpers.
require "json"
require "net/http"
require "uri"

module Load
  class Client
    HTTP_TIMEOUT_SECONDS = 5

    class Connection
      def initialize(http)
        @http = http
      end

      def start
        self
      end

      def request(request)
        @http.request(request)
      end

      def finish
      end
    end

    def initialize(base_url:, http: Net::HTTP, timeout_seconds: HTTP_TIMEOUT_SECONDS)
      @base_url = URI(base_url)
      @http = http
      @timeout_seconds = timeout_seconds
      @connection = nil
    end

    def get(path)
      request(:get, path)
    end

    def start
      return self if @connection

      @connection = connection_session(build_connection)
      self
    end

    def finish
      return unless @connection

      @connection.finish if !@connection.respond_to?(:started?) || @connection.started?
      @connection = nil
    end

    def request(method, path, body: nil, headers: {})
      uri = uri_for(path)
      request_class = Net::HTTP.const_get(method.to_s.capitalize)
      request = request_class.new(uri)
      headers.each { |key, value| request[key] = value }
      request.body = body.is_a?(String) ? body : JSON.generate(body) if body
      request["Content-Type"] ||= "application/json" if body

      if @connection
        @connection.request(request)
      elsif @http.respond_to?(:new)
        connection = build_connection
        begin
          session = connection_session(connection)
          session.request(request)
        ensure
          session.finish if session
        end
      else
        @http.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
          configure_timeouts(http)
          http.request(request)
        end
      end
    end

    private

    def uri_for(path)
      URI.join(@base_url.to_s.end_with?("/") ? @base_url.to_s : "#{@base_url}/", path.sub(/\A\//, ""))
    end

    def connection_session(connection)
      connection.start || connection
    end

    def configure_timeouts(http)
      http.open_timeout = @timeout_seconds if http.respond_to?(:open_timeout=)
      http.read_timeout = @timeout_seconds if http.respond_to?(:read_timeout=)
      http.write_timeout = @timeout_seconds if http.respond_to?(:write_timeout=)
      http.keep_alive_timeout = 30 if http.respond_to?(:keep_alive_timeout=)
    end

    def build_connection
      return Connection.new(@http) unless @http.respond_to?(:new)

      connection = @http.new(@base_url.host, @base_url.port)
      connection.use_ssl = @base_url.scheme == "https" if connection.respond_to?(:use_ssl=)
      configure_timeouts(connection)
      connection
    end
  end
end
```

The Rails adapter is where local Docker and remote PlanetScale diverge. The public `call` method dispatches by `BENCH_ADAPTER_RESET_STRATEGY`, then both strategies converge on the same `pg_stat_statements` setup, query-id capture, and counter reset so the rest of the load runner can treat them identically.

```bash
sed -n '1,95p' adapters/rails/lib/rails_adapter/commands/reset_state.rb
```

```output
# ABOUTME: Resets the benchmark database by rebuilding or cloning a template copy.
# ABOUTME: Reruns pg_stat_statements_reset after seeding so run counters start clean.
require "json"
require "uri"

module RailsAdapter
  module Commands
    class ResetState
      def initialize(app_root:, seed:, env_pairs:, workload: nil, command_runner: RailsAdapter::CommandRunner.new, template_cache: RailsAdapter::TemplateCache.new, reset_strategy: ENV.fetch("BENCH_ADAPTER_RESET_STRATEGY", "local"), workload_root: File.join(RailsAdapter::REPO_ROOT, "workloads"), clock: -> { Time.now.to_f })
        @app_root = app_root
        @workload = workload
        @seed = seed
        @env_pairs = env_pairs
        @command_runner = command_runner
        @template_cache = template_cache
        @reset_strategy = reset_strategy
        @workload_root = workload_root
        @clock = clock
      end

      def call
        case @reset_strategy
        when "local"
          reset_local
        when "remote"
          reset_remote
        else
          raise ArgumentError, "unknown reset strategy: #{@reset_strategy}"
        end

        ensure_pg_stat_statements
        query_ids = capture_query_ids
        reset_pg_stat_statements
        RailsAdapter::Result.ok("reset-state", query_ids ? { "query_ids" => query_ids } : {})
      rescue StandardError => error
        RailsAdapter::Result.error("reset-state", "reset_failed", error.message, {})
      end

      private

      def reset_local
        if @template_cache.template_exists?(database_name: database_name, app_root: @app_root, env_pairs: seed_env)
          @template_cache.clone_template(database_name: database_name, app_root: @app_root, env_pairs: seed_env)
        else
          build_template
          @template_cache.build_template(database_name: database_name, app_root: @app_root, env_pairs: seed_env)
        end
      end

      def reset_remote
        schema = @command_runner.capture3(
          "bin/rails",
          "db:schema:load",
          env: rails_env,
          chdir: @app_root,
          command_name: "reset-state",
        )
        raise command_failure_message("schema load failed", schema.stderr) unless schema.success?

        load_dataset = RailsAdapter::Commands::LoadDataset.new(
          app_root: @app_root,
          workload: @workload,
          seed: @seed,
          env_pairs: @env_pairs,
          command_runner: @command_runner,
          clock: @clock,
        ).call
        raise result_failure_message("seed failed", load_dataset) unless load_dataset.fetch("ok")
      end

      def build_template
        drop = @command_runner.capture3("bin/rails", "db:drop", env: rails_env, chdir: @app_root, command_name: "reset-state")
        raise command_failure_message("db:drop failed", drop.stderr) unless drop.success?

        migrate = RailsAdapter::Commands::Migrate.new(app_root: @app_root, command_runner: @command_runner).call
        raise result_failure_message("db:create db:schema:load failed", migrate) unless migrate.fetch("ok")

        load_dataset = RailsAdapter::Commands::LoadDataset.new(
          app_root: @app_root,
          workload: @workload,
          seed: @seed,
          env_pairs: @env_pairs,
          command_runner: @command_runner,
          clock: @clock,
        ).call
        raise result_failure_message("seed runner failed", load_dataset) unless load_dataset.fetch("ok")
      end

      def reset_pg_stat_statements
        result = @command_runner.capture3(
          "bin/rails",
          "runner",
          %(ActiveRecord::Base.connection.execute("SELECT pg_stat_statements_reset()")),
          env: rails_env,
          chdir: @app_root,
```

Remote reset deliberately avoids the local template database cache. For a managed database, the reset is `db:schema:load` followed by the same seed loader used locally. The review follow-up made all reset failures append stderr or nested result details, because PlanetScale integration failures are otherwise impossible to diagnose from the adapter JSON alone.

```bash
sed -n '95,178p' adapters/rails/lib/rails_adapter/commands/reset_state.rb
```

```output
          chdir: @app_root,
          command_name: "reset-state",
        )
        raise command_failure_message("pg_stat_statements_reset failed", result.stderr) unless result.success?
      end

      def ensure_pg_stat_statements
        result = @command_runner.capture3(
          "bin/rails",
          "runner",
          %(ActiveRecord::Base.connection.execute("CREATE EXTENSION IF NOT EXISTS pg_stat_statements")),
          env: rails_env,
          chdir: @app_root,
          command_name: "reset-state",
        )
        raise command_failure_message("pg_stat_statements extension failed", result.stderr) unless result.success?
      end

      def capture_query_ids
        path = query_ids_script_path
        return nil unless path

        result = @command_runner.capture3(
          "bin/rails",
          "runner",
          path,
          env: rails_env,
          chdir: @app_root,
          command_name: "reset-state",
        )
        raise command_failure_message("query id capture failed", result.stderr) unless result.success?

        query_ids = JSON.parse(result.stdout).fetch("query_ids")
        raise TypeError, "query_ids must be an array" unless query_ids.is_a?(Array)

        query_ids
      end

      def query_ids_script_path
        return nil unless @workload

        path = File.join(@workload_root, @workload.tr("-", "_"), "rails", "reset_state_query_ids.rb")
        File.exist?(path) ? path : nil
      end

      def command_failure_message(message, detail)
        detail = detail.to_s.strip
        detail.empty? ? message : "#{message}: #{detail}"
      end

      def result_failure_message(message, result)
        error = result.fetch("error")
        details = error.fetch("details", {})
        [
          message,
          error.fetch("message", nil),
          details.fetch("stderr", nil),
        ].compact.map(&:to_s).map(&:strip).reject(&:empty?).join(": ")
      end

      def database_name
        return ENV.fetch("BENCHMARK_DB_NAME") if ENV.key?("BENCHMARK_DB_NAME")

        database_url = ENV["DATABASE_URL"]
        return "checkpoint_demo" unless database_url

        path = URI.parse(database_url).path
        name = path.sub(%r{\A/}, "")
        name.empty? ? "checkpoint_demo" : name
      end

      def rails_env
        RailsAdapter::Environment.benchmark(@app_root)
      end

      def seed_env
        @seed_env ||= @env_pairs.merge("SEED" => @seed.to_s)
      end
    end
  end
end
```

The reset tests define the contract. The remote strategy test proves command order and that the template cache is bypassed. The failure tests prove operators see both the phase label and the underlying stderr/result message.

```bash
sed -n '42,132p' adapters/rails/test/reset_state_test.rb
```

```output
    assert_equal 1, cache.clone_calls
    assert_includes runner.argv_history, ["bin/rails", "db:drop"]
    assert_includes runner.argv_history, ["bin/rails", "db:create", "db:schema:load"]
  end

  def test_reset_state_remote_strategy_skips_template_cache_and_runs_schema_seed_and_stats_steps
    Dir.mktmpdir do |workload_root|
      script_body = query_ids_script_body
      script_path = write_workload_query_ids_script(root: workload_root, workload: "missing-index-todos", body: script_body)
      query_ids_json = %({"query_ids":["111"]})
      runner = FakeCommandRunner.new(
        results: {
          ["bin/rails", "runner", script_path] => FakeResult.new(status: 0, stdout: query_ids_json, stderr: ""),
        },
      )
      cache = FakeTemplateCache.new
      command = RailsAdapter::Commands::ResetState.new(
        app_root: "/tmp/demo",
        workload: "missing-index-todos",
        seed: 42,
        env_pairs: { "ROWS_PER_TABLE" => "100000", "OPEN_FRACTION" => "0.6", "USER_COUNT" => "100" },
        command_runner: runner,
        template_cache: cache,
        reset_strategy: "remote",
        workload_root:,
        clock: fake_clock(0.0, 1.0),
      )

      result = command.call

      assert result.fetch("ok"), result.inspect
      assert_equal ["111"], result.fetch("query_ids")
      assert_equal 0, cache.build_calls
      assert_equal 0, cache.clone_calls
      assert_equal [
        ["bin/rails", "db:schema:load"],
        ["bin/rails", "runner", %(load Rails.root.join("db/seeds.rb").to_s)],
        ["bin/rails", "runner", %(ActiveRecord::Base.connection.execute("CREATE EXTENSION IF NOT EXISTS pg_stat_statements"))],
        ["bin/rails", "runner", script_path],
        ["bin/rails", "runner", %(ActiveRecord::Base.connection.execute("SELECT pg_stat_statements_reset()"))],
      ], runner.argv_history
    end
  end

  def test_reset_state_skips_query_id_capture_when_workload_script_is_absent
    Dir.mktmpdir do |workload_root|
      runner = FakeCommandRunner.new
      command = RailsAdapter::Commands::ResetState.new(
        app_root: "/tmp/demo",
        workload: "fixture-workload",
        seed: 42,
        env_pairs: {},
        command_runner: runner,
        template_cache: FakeTemplateCache.new,
        reset_strategy: "remote",
        workload_root:,
        clock: fake_clock(0.0, 1.0),
      )

      result = command.call

      assert result.fetch("ok"), result.inspect
      refute result.key?("query_ids")
      refute runner.argv_history.any? { |argv| argv.first(2) == ["bin/rails", "runner"] && argv.fetch(2).include?("query_ids") }
    end
  end

  def test_reset_state_skips_query_id_capture_when_workload_is_nil
    Dir.mktmpdir do |workload_root|
      runner = FakeCommandRunner.new
      command = RailsAdapter::Commands::ResetState.new(
        app_root: "/tmp/demo",
        seed: 42,
        env_pairs: {},
        command_runner: runner,
        template_cache: FakeTemplateCache.new(template_exists: true),
        reset_strategy: "remote",
        workload_root:,
        clock: fake_clock(0.0, 1.0),
      )

      result = command.call

      assert result.fetch("ok"), result.inspect
      refute result.key?("query_ids")
    end
  end

  def test_reset_state_remote_strategy_reports_schema_load_failure
    runner = FakeCommandRunner.new(
      results: {
```

Before workers start, the missing-index workload verifier still runs against the live app. The default client now has a 30 second timeout because the PlanetScale `/api/todos/counts` preflight was slow enough after reset that the old five second default could fail the integration before the workload began.

```bash
sed -n '1,90p' workloads/missing_index_todos/verifier.rb
```

```output
# ABOUTME: Verifies the missing-index workload fixture still exposes its intended pathologies.
# ABOUTME: Checks the user-scoped scan, counts fan-out, and tenant-scoped search explain shape.
require "json"
require "pg"
require_relative "plan_contract"

module Load
  module Workloads
    module MissingIndexTodos
      class Verifier
        SEARCH_PLAN_STABLE_KEYS = ["Node Type", "Relation Name", "Sort Key", "Filter", "Plans"].freeze
        COUNTS_PATH = "/api/todos/counts".freeze
        MISSING_INDEX_PATH = "/api/todos?user_id=1&status=open".freeze
        SEARCH_PATH = "/api/todos/search?user_id=1&q=foo".freeze
        MISSING_INDEX_SQL = <<~SQL.freeze
          EXPLAIN (FORMAT JSON)
          SELECT *
          FROM todos
          WHERE user_id = 1 AND status = 'open'
          ORDER BY created_at DESC, id DESC
          LIMIT 50
        SQL
        SEARCH_SQL = <<~SQL.freeze
          EXPLAIN (FORMAT JSON)
          SELECT *
          FROM todos
          WHERE user_id = 1 AND title LIKE '%foo%'
          ORDER BY created_at DESC, id DESC
          LIMIT 50
        SQL
        COUNTS_CALLS_SQL = <<~SQL.freeze
          SELECT COALESCE(SUM(calls), 0)::bigint AS calls
          FROM pg_stat_statements
          WHERE query LIKE '%FROM "todos"%'
            AND query LIKE '%COUNT(%'
            AND query LIKE '%"todos"."user_id"%'
        SQL

        def self.build_explain_reader(database_url:, pg:)
          ensure_database_url!(database_url)
          lambda do |sql|
            with_connection(database_url:, pg:) do |connection|
              rows = connection.exec(sql)
              JSON.parse(rows.first.fetch("QUERY PLAN")).fetch(0).fetch("Plan")
            end
          end
        end

        def self.build_stats_reset(database_url:, pg:)
          ensure_database_url!(database_url)
          lambda do
            with_connection(database_url:, pg:) do |connection|
              connection.exec("SELECT pg_stat_statements_reset()")
            end
          end
        end

        def self.build_counts_calls_reader(database_url:, pg:)
          ensure_database_url!(database_url)
          lambda do
            with_connection(database_url:, pg:) do |connection|
              connection.exec(COUNTS_CALLS_SQL).first.fetch("calls")
            end
          end
        end

        def self.with_connection(database_url:, pg:)
          connection = pg.connect(database_url)
          yield connection
        ensure
          connection&.close
        end

        def self.ensure_database_url!(database_url)
          return database_url unless database_url.nil? || database_url.empty?

          raise ArgumentError, "missing DATABASE_URL for fixture verification"
        end

        def initialize(client_factory: nil, explain_reader: nil, stats_reset: nil, counts_calls_reader: nil, search_reference_reader: nil, database_url: ENV["DATABASE_URL"], pg: PG)
          @client_factory = client_factory || ->(base_url) { Load::Client.new(base_url:, timeout_seconds: 30) }
          @explain_reader = explain_reader || self.class.build_explain_reader(database_url:, pg:)
          @stats_reset = stats_reset || self.class.build_stats_reset(database_url:, pg:)
          @counts_calls_reader = counts_calls_reader || self.class.build_counts_calls_reader(database_url:, pg:)
          @search_reference_reader = search_reference_reader || -> { JSON.parse(File.read(search_reference_path)).fetch(0).fetch("Plan") }
        end

        def call(base_url:)
          {
            ok: true,
```

Continuous soak also samples workload invariants. PlanetScale does not allow this role to change `pg_stat_statements.track`, so the sampler treats that privilege failure as a non-fatal setup limitation and still reads the invariant counts.

```bash
sed -n '1,115p' workloads/missing_index_todos/invariant_sampler.rb
```

```output
# ABOUTME: Samples missing-index todo table invariants using an isolated PG connection.
# ABOUTME: Returns named invariant checks for open and total todo counts.
require_relative "../../load/lib/load"

module Load
  module Workloads
    module MissingIndexTodos
      class InvariantSampler
        OPEN_COUNT_SQL = "SELECT COUNT(*) AS count FROM todos WHERE status = 'open'".freeze
        TOTAL_COUNT_SQL = "SELECT reltuples::bigint AS count FROM pg_class WHERE relname = 'todos'".freeze
        DISABLE_TRACKING_SQL = "SET pg_stat_statements.track = 'none'".freeze

        def initialize(pg:, database_url:, open_floor:, total_floor:, total_ceiling:, stderr: $stderr)
          @pg = pg
          @database_url = database_url
          @open_floor = open_floor
          @total_floor = total_floor
          @total_ceiling = total_ceiling
          @stderr = stderr
          @tracking_warning_emitted = false
        end

        def call
          with_connection do |connection|
            disable_tracking(connection)
            open_count = connection.exec(OPEN_COUNT_SQL).first.fetch("count").to_i
            total_count = connection.exec(TOTAL_COUNT_SQL).first.fetch("count").to_i
            Load::Runner::InvariantSample.new(
              [
                Load::Runner::InvariantCheck.new("open_count", open_count, @open_floor, nil),
                Load::Runner::InvariantCheck.new("total_count", total_count, @total_floor, @total_ceiling),
              ],
            )
          end
        end

        private

        def disable_tracking(connection)
          connection.exec(DISABLE_TRACKING_SQL)
        rescue PG::InsufficientPrivilege
          unless @tracking_warning_emitted
            @stderr.puts("warning: unable to disable pg_stat_statements tracking for invariant sampler")
            @tracking_warning_emitted = true
          end
          nil
        end

        def with_connection
          connection = @pg.connect(@database_url)
          yield connection
        ensure
          connection&.close
        end
      end
    end
  end
end
```

The collector change makes PlanetScale practical. The same process still polls `pg_stat_statements` and writes query interval rows to ClickHouse, but `COLLECTOR_DISABLE_LOG_INGESTION=1` skips the Docker log tailing path entirely. That keeps local Docker behavior as the default while allowing remote Postgres runs.

```bash
sed -n '92,205p' collector/bin/collector
```

```output
    interval_seconds:,
    postgres_url:,
    clickhouse_url:,
    log_file: DEFAULT_LOG_FILE,
    clock: -> { Time.now.utc },
    sleep_until: nil,
    stderr: $stderr,
    pg: PG,
    scheduler_class: Scheduler,
    collector_class: Collector,
    log_ingester_class: LogIngester,
    clickhouse_connection_class: ClickhouseConnection,
    state_store_class: ClickhouseLogStateStore,
    state_store_transport: nil,
    log_reader: nil,
    log_ingestion_enabled: ENV.fetch("COLLECTOR_DISABLE_LOG_INGESTION", nil).nil?
  )
    @interval_seconds = interval_seconds
    @postgres_url = postgres_url
    @clickhouse_url = clickhouse_url
    @log_file = log_file
    @clock = clock
    @sleep_until = sleep_until || default_sleep_until
    @stderr = stderr
    @pg = pg
    @scheduler_class = scheduler_class
    @collector_class = collector_class
    @log_ingester_class = log_ingester_class
    @clickhouse_connection_class = clickhouse_connection_class
    @state_store_class = state_store_class
    @state_store_transport = state_store_transport
    @log_reader = log_reader || default_log_reader
    @log_ingestion_enabled = log_ingestion_enabled
  end

  def run_forever
    scheduler.run_forever
  end

  def run_once_pass
    stats_connection = @pg.connect(@postgres_url)
    clickhouse_connection = @clickhouse_connection_class.new(base_url: @clickhouse_url)
    state_store = @state_store_class.new(base_url: @clickhouse_url, transport: @state_store_transport)

    if @log_ingestion_enabled
      @log_ingester_class.new(
        log_reader: @log_reader,
        clickhouse_connection: clickhouse_connection,
        state_store: state_store,
        clock: @clock,
        stderr: @stderr
      ).ingest_file(@log_file)
    end

    @collector_class.new(
      stats_connection: stats_connection,
      clickhouse_connection: clickhouse_connection,
      clock: @clock
    ).run_once
  ensure
    stats_connection&.close
  end

  private

  def scheduler
    @scheduler_class.new(
      interval_seconds: @interval_seconds,
      clock: @clock,
      sleep_until: @sleep_until,
      stderr: @stderr,
      run_once: -> { run_once_pass }
    )
  end

  def default_sleep_until
    lambda do |time|
      seconds = time - Time.now.utc
      sleep(seconds) if seconds.positive?
    end
  end

  def default_log_reader
    lambda do |log_file, byte_offset|
      File.open(log_file, "rb") do |file|
        file.seek(byte_offset)
        file.read.to_s
      end
    rescue Errno::ENOENT
      ""
    end
  end
end

if $PROGRAM_NAME == __FILE__
  CollectorRuntime.new(
    interval_seconds: Integer(ENV.fetch("COLLECTOR_INTERVAL_SECONDS", "5")),
    postgres_url: ENV.fetch("POSTGRES_URL"),
    clickhouse_url: ENV.fetch("CLICKHOUSE_URL"),
    log_file: ENV.fetch("POSTGRES_LOG_PATH", CollectorRuntime::DEFAULT_LOG_FILE),
  ).run_forever
end
```

The collector tests lock down both sides of that behavior: an explicit false flag skips log reads while collecting stats, and the environment default is owned by `CollectorRuntime` rather than duplicated by the executable entrypoint.

```bash
sed -n '112,182p' collector/test/runtime_orchestration_test.rb
```

```output
    events = []
    clickhouse_service = FakeClickhouseService.new(events: events)
    observed_offsets = []
    stats_connections = []
    clickhouse_connections = []

    runtime = build_runtime(
      events: events,
      clickhouse_service: clickhouse_service,
      observed_offsets: observed_offsets,
      stats_connections: stats_connections,
      clickhouse_connections: clickhouse_connections,
      log_reader: lambda do |_, byte_offset|
        observed_offsets << byte_offset
        raise "log reader should not be called"
      end,
      log_ingestion_enabled: false,
    )

    runtime.run_once_pass

    assert_equal [], observed_offsets
    assert_equal [
      [:stats_exec, 1, Collector::STATS_SQL],
      [:stats_exec, 1, Collector::INFO_SQL],
      [:insert, 1, "query_events"],
      [:stats_close, 1],
    ], events
  end

  def test_runtime_uses_environment_default_for_log_ingestion
    events = []
    clickhouse_service = FakeClickhouseService.new(events: events)
    observed_offsets = []

    with_env("COLLECTOR_DISABLE_LOG_INGESTION" => "1") do
      runtime = build_runtime(
        events: events,
        clickhouse_service: clickhouse_service,
        observed_offsets: observed_offsets,
        stats_connections: [],
        clickhouse_connections: [],
        log_reader: lambda do |_, byte_offset|
          observed_offsets << byte_offset
          raise "log reader should not be called"
        end,
        use_log_ingestion_default: true,
      )

      runtime.run_once_pass
    end

    assert_equal [], observed_offsets
    assert_equal [
      [:stats_exec, 1, Collector::STATS_SQL],
      [:stats_exec, 1, Collector::INFO_SQL],
      [:insert, 1, "query_events"],
      [:stats_close, 1],
    ], events
  end

  def test_executable_entrypoint_uses_runtime_log_ingestion_default
    source = File.read(File.expand_path("../bin/collector", __dir__))
    executable_block = source.split('if $PROGRAM_NAME == __FILE__', 2).fetch(1)

    refute_includes executable_block, "log_ingestion_enabled:"
  end

  private

  def build_runtime(events:, clickhouse_service:, observed_offsets:, stats_connections:, clickhouse_connections:, log_reader:, clickhouse_url: "http://clickhouse:8123", log_ingestion_enabled: true, use_log_ingestion_default: false)
```

Two workload-side changes are adjacent to PlanetScale but not PlanetScale-specific. `CloseTodo` now understands the app response envelope, which fixed live soak request errors. The verifier and invariant changes above make the remote integration tolerant of managed-database latency and privilege limits without weakening the core workload oracle.

```bash
sed -n '1,90p' workloads/missing_index_todos/actions/close_todo.rb
```

```output
# ABOUTME: Defines the close-todo request used in the mixed missing-index workload.
# ABOUTME: Marks one todo closed through the shared client using a fixture-friendly id.
require "json"

require_relative "../../../load/lib/load"

module Load
  module Workloads
    module MissingIndexTodos
      module Actions
        class CloseTodo < Load::Action
          NoOpResponse = Struct.new(:code, :body)

          def name
            :close_todo
          end

          def call
            todo_id = open_todo_ids.sample(random: rng)
            return NoOpResponse.new("204", "") unless todo_id

            client.request(:patch, "/api/todos/#{todo_id}", body: { status: "closed" })
          end

          private

          def open_todo_ids
            response = client.get("/api/todos?user_id=#{sample_user_id}&status=open")
            JSON.parse(response.body.to_s).fetch("items").map { |todo| todo.fetch("id") }
          end

          def sample_user_id
            user_count = Integer(ctx.fetch(:scale).extra.fetch(:user_count))
            rng.rand(1..user_count)
          end
        end
      end
    end
  end
end
```

The explicit future-work surface matters because Brett deferred branch-per-run and PlanetScale query-log ingestion. Those ideas are preserved in TODO/JOURNAL while this branch stays scoped to reset/reseed plus `pg_stat_statements` evidence.

```bash
grep -n -E 'PlanetScale|branch|Logs|Insights|pg_stat_statements' TODO.md JOURNAL.md | tail -20
```

```output
JOURNAL.md:14:- The missing-index template must create `pg_stat_statements` itself; otherwise `fixture_01` clones successfully but `pg_stat_statements_reset()` fails at the end of reset.
JOURNAL.md:24:- 2026-04-19 verification follow-up: forcing `COMPOSE_PROJECT_NAME=checkpoint-collector` in the smoke helpers makes pytest reuse the intended stack from a worktree, and the first smoke test needed to poll for its specific `pg_stat_statements` row instead of any `postgres_logs` row to avoid a clean-stack ingestion race.
JOURNAL.md:43:- The Postgres compose service initially came up healthy without publishing `5432`; forcing a recreate restored the host port binding, and `reset-state` also has to `CREATE EXTENSION IF NOT EXISTS pg_stat_statements` before calling `pg_stat_statements_reset()`.
JOURNAL.md:48:- The Rails adapter template cache must key template databases by schema digest, not just database name; otherwise switching the benchmark app to a different branch silently reuses a stale template and parity checks lie.
JOURNAL.md:49:- The raw `oracle/add-index` tag is not sufficient under the `db:schema:load` adapter contract: it adds a migration file but leaves `db/schema.rb` without the `todos.status` index, so the negative control needs a temporary branch that also materializes the indexed schema.
JOURNAL.md:50:- 2026-04-21/22 parity SHAs: `~/db-specialist-demo` baseline `wip/load-benchmark-seeds` at `1a49917`; negative control branch `parity/oracle-add-index-benchmark-seeds` at `d209413` (oracle tag + benchmark seeds + `/up` + indexed `db/schema.rb`).
JOURNAL.md:53:- 2026-04-22 negative control debugging: the first indexed-branch attempt timed out on readiness because `oracle/add-index` predates `/up`; after cherry-picking the liveness endpoint it still falsely passed until the schema-digest cache fix landed and the temporary branch materialized the indexed schema in `db/schema.rb`.
JOURNAL.md:94:- 2026-04-25 operator docs: the top-level README now has one run-modes section covering `bin/load run`, `bin/load soak`, and `bin/load verify-fixture`, including intent, artifact expectations, and sample output drawn from the real finite and degraded-soak runs on this branch.
JOURNAL.md:120:- 2026-04-25 Task 1.5 adapter query-id capture: the live normalized `pg_stat_statements.query` for `user.todos.with_status("open").ordered_by_created_desc.page(1, 50).load` in `/home/bjw/db-specialist-demo` is `SELECT "todos".* FROM "todos" WHERE "todos"."user_id" = $1 AND "todos"."status" = $2 ORDER BY "todos"."created_at" DESC, "todos"."id" DESC LIMIT $3 OFFSET $4`.
JOURNAL.md:127:- 2026-04-26 invariant monitor Task 2/3: `Load::InvariantMonitor` now groups policy and effects into nested `Config`, `Sink`, and `State`, keeps policy branching in `sample_once`, uses `State#with_sleeping` only for sleep-flag toggling under the existing `Thread.handle_interrupt` discipline, and preserves clear-and-raise-once sampler failure handling while the runner builds the grouped constructor args.
JOURNAL.md:131:- 2026-04-26 PlanetScale soak design notes: PlanetScale Postgres supports `pg_stat_statements` after dashboard activation and `CREATE EXTENSION`, but the current local collector also tails Docker-mounted Postgres JSON logs, so remote soak should make stats polling usable without local log ingestion. Brett explicitly deferred branch-per-run; current design scope is reset/reseed against an existing PlanetScale branch, with branch automation tracked as future work.
JOURNAL.md:132:- 2026-04-26 PlanetScale logs decision: PlanetScale has Cluster Logs and Query Insights/`pginsights`, and pganalyze can collect PlanetScale logs with a service token, but Brett agreed not to block the reset/reseed pass on remote log ingestion. Current implementation should be stats-only for PlanetScale, with logs/Insights integration tracked as a fast follow.
JOURNAL.md:133:- 2026-04-26 PlanetScale reset checkpoint: remote reset-state against the existing branch succeeded after enabling `pg_stat_statements` in the PlanetScale dashboard. Local libpq 18.0.1 failed certificate verification with `sslrootcert=system`, but `sslmode=verify-full&sslrootcert=/etc/ssl/certs/ca-certificates.crt` worked. Reset seeded `100000` todos with `59859` open todos, captured one query id (`-5699193110986258845`), and updated `pg_stat_statements_info.stats_reset` at `2026-04-26 18:25:29.285509+00`.
JOURNAL.md:134:- 2026-04-26 PlanetScale collector checkpoint: stats-only collector pass against PlanetScale wrote rows to the existing `checkpoint-collector-clickhouse-1` instance on localhost because this worktree could not bind `8123`. `query_events` increased from `65043` to `65341`, latest `collected_at` became `2026-04-26 18:35:45.093`, and no Postgres log file was read. The plan's `ruby -r./collector/bin/collector` command does not load a relative file here; use `ruby -e 'load "./collector/bin/collector"; ...'` instead.
JOURNAL.md:135:- 2026-04-26 PlanetScale local verification: `make test-load` passed with `156 runs, 528 assertions`; `make test-adapters` passed with `26 runs, 75 assertions, 2 skips`; `make test-workloads` passed with `52 runs, 215 assertions`; and `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby -e 'Dir["collector/test/*_test.rb"].sort.each { |path| load path }'` passed with `55 runs, 171 assertions`.
JOURNAL.md:136:- 2026-04-26 PlanetScale final soak checkpoint: successful remote soak evidence is `runs/20260426T190638Z-missing-index-todos`, run with `BENCH_ADAPTER_RESET_STRATEGY=remote`, explicit CA bundle URLs, `--startup-grace-seconds 60`, and `--invariants warn`. The run reset/seeding captured query id `-5699193110986258845`, readiness completed after `6117ms`, workers ran from `19:07:14 UTC` to `19:09:11 UTC`, SIGINT stopped cleanly, and `run.json` recorded `2771` total requests, `2742` ok, `29` errors, plus one healthy invariant sample. ClickHouse had target queryid evidence for `-5699193110986258845` with `10637` interval calls and estimated `14626.7ms` total exec time. Integration fixes discovered during this checkpoint: verifier HTTP timeout needed 30s for PlanetScale `/api/todos/counts`, and the invariant sampler must tolerate lack of permission to set `pg_stat_statements.track`.
JOURNAL.md:137:- 2026-04-26 PlanetScale final verification: after the verifier-timeout and invariant-sampler fixes, `make test-workloads` passed with `54 runs, 225 assertions`, collector tests passed with `55 runs, 171 assertions`, `make test-adapters` passed with `26 runs, 75 assertions, 2 skips`, and `make test-load` passed on rerun with `157 runs, 532 assertions`. The first full `make test-load` attempt hit a non-reproducing failure in `test_runner_warn_policy_records_breaches_without_aborting`; that test passed in isolation and the serial suite rerun passed.
JOURNAL.md:138:- 2026-04-26 PlanetScale review follow-up: keep `COLLECTOR_DISABLE_LOG_INGESTION` interpretation centralized in `CollectorRuntime` instead of also passing `log_ingestion_enabled` from the executable entrypoint. Reset failures should surface stderr/details in the adapter JSON error message; otherwise PlanetScale privilege or TLS failures become opaque during destructive reset/reseed checkpoints.
JOURNAL.md:139:- 2026-04-26 PlanetScale operator debug: a `make load-soak-planetscale` failure with no output was caused by the exported PlanetScale URLs still using `sslrootcert=system`; Rails/PG failed in `prepare` with `SSL error: certificate verify failed`. Replacing only that query param with `sslrootcert=/etc/ssl/certs/ca-certificates.crt` made adapter `prepare` succeed. The load runner now prints and persists structured adapter JSON error messages so this failure is visible at the Make target.
JOURNAL.md:140:- 2026-04-26 PlanetScale URL contract: the canonical direct connection URL for this branch is `postgresql://USER:PASSWORD@HOST:5432/postgres?sslmode=verify-full&sslrootcert=/etc/ssl/certs/ca-certificates.crt`. Operators must export the complete URL for `DATABASE_URL`, `BENCH_ADAPTER_PG_ADMIN_URL`, and `POSTGRES_URL`; the runner, adapter, and collector intentionally pass URLs through and do not append SSL parameters.
```

Finally, the branch has targeted tests for the changed behavior. These are the quickest commands to run when editing this area: reset-state tests for adapter semantics, collector orchestration tests for stats-only mode, workload tests for verifier/invariant/action behavior, and load tests for runner/client wiring.

```bash
printf '%s\n' 'BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby adapters/rails/test/reset_state_test.rb' 'BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby collector/test/runtime_orchestration_test.rb' 'make test-workloads' 'make test-load'
```

```output
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby adapters/rails/test/reset_state_test.rb
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby collector/test/runtime_orchestration_test.rb
make test-workloads
make test-load
```
