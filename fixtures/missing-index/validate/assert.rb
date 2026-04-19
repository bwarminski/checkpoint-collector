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
        @stdout.puts("PASS: explain (#{plan.fetch("Node Type")} on #{plan.fetch("Relation Name")}, root node confirmed)")
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
