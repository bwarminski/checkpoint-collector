# ABOUTME: Verifies the missing-index workload reproduced both the bad plan and ClickHouse activity.
# ABOUTME: Reads a run record, tree-walks EXPLAIN JSON, and polls ClickHouse by queryid fingerprints.
require "json"
require "net/http"
require "optparse"
require "pg"
require "time"
require "uri"

module Load
  module Workloads
    module MissingIndexTodos
      class Oracle
        CLICKHOUSE_CALL_THRESHOLD = 500
        DOMINANCE_RATIO_THRESHOLD = 3.0
        USER_ID_INDEX_NAME = "index_todos_on_user_id".freeze
        EXPECTED_SORT_KEY = ["created_at DESC", "id DESC"].freeze
        CLICKHOUSE_TOPN_LIMIT = 10
        EXPLAIN_SQL = <<~SQL.freeze
          EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
          SELECT *
          FROM todos
          WHERE user_id = 1 AND status = 'open'
          ORDER BY created_at DESC, id DESC
          LIMIT 50
        SQL

        class Failure < StandardError
        end

        def initialize(stdout: $stdout, stderr: $stderr, pg: PG, clickhouse_query: nil, clickhouse_topn_query: nil, clock: -> { Time.now.utc }, sleeper: ->(seconds) { sleep(seconds) })
          @stdout = stdout
          @stderr = stderr
          @pg = pg
          @clickhouse_query = clickhouse_query || method(:query_clickhouse)
          @clickhouse_topn_query = clickhouse_topn_query || method(:query_clickhouse_topn)
          @clock = clock
          @sleeper = sleeper
        end

        def run(argv)
          options = parse(argv)
          result = call(**options)

          @stdout.puts("PASS: explain (#{result.fetch(:plan).fetch("Node Type")} on todos, plan node confirmed)")
          @stdout.puts("PASS: clickhouse (#{result.fetch(:clickhouse).fetch("total_exec_count")} calls; mean #{result.fetch(:clickhouse).fetch("mean_exec_time_ms")}ms)")
          @stdout.puts(result.fetch(:dominance).fetch("message"))
          exit 0
        rescue Failure => error
          @stderr.puts(error.message)
          exit 1
        end

        def call(run_dir:, database_url:, clickhouse_url:, timeout_seconds: 30)
          run_record = load_run_record(run_dir)
          queryids = extract_queryids(run_record)
          plan = explain_todos_scan(database_url)
          clickhouse = wait_for_clickhouse!(
            window: run_record.fetch("window"),
            queryids:,
            clickhouse_url:,
            timeout_seconds:
          )
          dominance = assert_dominance(
            window: run_record.fetch("window"),
            expected_queryids: queryids,
            clickhouse_url:,
          )

          {
            plan:,
            clickhouse: normalize_clickhouse_snapshot(clickhouse),
            dominance:,
          }
        end

        private

        def parse(argv)
          options = {
            database_url: ENV["DATABASE_URL"],
            clickhouse_url: ENV["CLICKHOUSE_URL"],
            timeout_seconds: 30,
          }

          parser = OptionParser.new
          parser.on("--database-url URL") { |value| options[:database_url] = value }
          parser.on("--clickhouse-url URL") { |value| options[:clickhouse_url] = value }
          parser.on("--timeout-seconds SECONDS", Integer) { |value| options[:timeout_seconds] = value }

          args = argv.dup
          parser.parse!(args)
          run_dir = args.shift
          raise Failure, "FAIL: missing run record directory" if run_dir.nil? || run_dir.empty?
          raise Failure, "FAIL: missing --database-url (or DATABASE_URL)" if options[:database_url].nil? || options[:database_url].empty?
          raise Failure, "FAIL: missing --clickhouse-url (or CLICKHOUSE_URL)" if options[:clickhouse_url].nil? || options[:clickhouse_url].empty?

          options.merge(run_dir:)
        end

        def load_run_record(run_dir)
          path = File.join(run_dir, "run.json")
          JSON.parse(File.read(path))
        rescue Errno::ENOENT
          raise Failure, "FAIL: missing run record at #{path}"
        end

        def extract_queryids(run_record)
          queryids = Array(run_record["query_ids"]).map(&:to_s).reject(&:empty?).uniq
          return queryids unless queryids.empty?

          raise Failure, "FAIL: run record is missing query_ids"
        end

        def explain_todos_scan(database_url)
          connection = @pg.connect(database_url)
          rows = connection.exec(EXPLAIN_SQL)
          payload = JSON.parse(rows.first.fetch("QUERY PLAN"))
          plan = payload.fetch(0).fetch("Plan")
          bitmap_heap_scan = find_missing_index_scan(plan)
          raise Failure, "FAIL: explain (expected Limit -> Sort -> Bitmap Heap Scan on todos)" unless bitmap_heap_scan
          raise Failure, "FAIL: explain (expected Recheck Cond to include user_id)" unless bitmap_heap_scan.fetch("Recheck Cond", "").to_s.include?("user_id")
          raise Failure, "FAIL: explain (expected status filter after tenant lookup)" unless bitmap_heap_scan.fetch("Filter", "").to_s.include?("status")

          index_scan = Array(bitmap_heap_scan["Plans"]).find { |node| node.fetch("Node Type") == "Bitmap Index Scan" }
          unless index_scan&.fetch("Index Name", "") == USER_ID_INDEX_NAME
            raise Failure, "FAIL: explain (expected Bitmap Index Scan using #{USER_ID_INDEX_NAME})"
          end

          bitmap_heap_scan
        ensure
          connection&.close
        end

        def find_missing_index_scan(node)
          return unless node.fetch("Node Type") == "Limit"

          Array(node["Plans"]).each do |sort_node|
            next unless sort_node.fetch("Node Type") == "Sort"
            next unless sort_node.fetch("Sort Key", []) == EXPECTED_SORT_KEY

            Array(sort_node["Plans"]).each do |child|
              next unless child["Relation Name"] == "todos"
              return child if child.fetch("Node Type") == "Bitmap Heap Scan"
            end
          end

          nil
        end

        def wait_for_clickhouse!(window:, queryids:, clickhouse_url:, timeout_seconds:)
          deadline = @clock.call + timeout_seconds

          loop do
            snapshot = normalize_clickhouse_snapshot(
              @clickhouse_query.call(window:, queryids:, clickhouse_url:)
            )
            return snapshot if snapshot.fetch("total_exec_count") >= CLICKHOUSE_CALL_THRESHOLD

            raise Failure, "FAIL: clickhouse (saw #{snapshot.fetch("total_exec_count")} calls before timeout)" if @clock.call >= deadline

            @sleeper.call(1)
          end
        end

        def normalize_clickhouse_snapshot(snapshot)
          {
            "total_exec_count" => snapshot.fetch("total_exec_count").to_i,
            "mean_exec_time_ms" => snapshot.fetch("mean_exec_time_ms", "0.0").to_s,
          }
        end

        def assert_dominance(window:, expected_queryids:, clickhouse_url:)
          rows = @clickhouse_topn_query.call(window:, clickhouse_url:)
          primary = rows.find { |row| expected_queryids.include?(row.fetch("queryid")) }
          raise Failure, "FAIL: dominance (primary queryid not present in top-N)" if primary.nil?

          challenger = rows.find { |row| !expected_queryids.include?(row.fetch("queryid")) }
          if challenger.nil?
            return { "message" => "PASS: dominance (no challenger; primary stands alone)" }
          end

          primary_time = primary.fetch("total_exec_time_ms_estimate").to_f
          challenger_time = challenger.fetch("total_exec_time_ms_estimate").to_f
          ratio = primary_time / challenger_time

          if primary_time >= challenger_time * DOMINANCE_RATIO_THRESHOLD
            { "message" => "PASS: dominance (#{ratio.round(2)}x over next queryid)" }
          else
            raise Failure,
              "FAIL: dominance (#{primary_time}ms / #{challenger_time}ms = #{ratio.round(2)}x; required: >=3x)"
          end
        end

        def query_clickhouse(window:, queryids:, clickhouse_url:)
          uri = URI.parse(clickhouse_url)
          uri.path = "/" if uri.path.to_s.empty?
          uri.query = URI.encode_www_form(query: "#{build_clickhouse_sql(window:, queryids:)} FORMAT JSONEachRow")
          response = Net::HTTP.get_response(uri)
          raise Failure, "FAIL: clickhouse (query failed: #{response.code} #{response.body})" if response.code.to_i >= 400

          body = response.body.to_s.each_line.first || "{\"total_exec_count\":\"0\",\"mean_exec_time_ms\":\"0.0\"}"
          JSON.parse(body)
        end

        def query_clickhouse_topn(window:, clickhouse_url:)
          uri = URI.parse(clickhouse_url)
          uri.path = "/" if uri.path.to_s.empty?
          uri.query = URI.encode_www_form(query: "#{build_clickhouse_topn_sql(window:)} FORMAT JSONEachRow")
          response = Net::HTTP.get_response(uri)
          raise Failure, "FAIL: clickhouse (query failed: #{response.code} #{response.body})" if response.code.to_i >= 400

          response.body.to_s.each_line.map { |line| JSON.parse(line) }
        end

        def build_clickhouse_sql(window:, queryids:)
          escaped_queryids = queryids.map { |queryid| "'#{queryid.gsub("'", "''")}'" }.join(", ")

          <<~SQL
            SELECT
              toString(coalesce(sum(total_exec_count), 0)) AS total_exec_count,
              toString(round(coalesce(avg(avg_exec_time_ms), 0), 1)) AS mean_exec_time_ms
            FROM query_intervals
            WHERE interval_ended_at BETWEEN parseDateTime64BestEffort('#{window.fetch("start_ts")}') AND parseDateTime64BestEffort('#{window.fetch("end_ts")}') + INTERVAL 90 SECOND
              AND queryid IN (#{escaped_queryids})
          SQL
        end

        def build_clickhouse_topn_sql(window:)
          <<~SQL
            SELECT
              toString(queryid) AS queryid,
              toString(sum(total_exec_count)) AS total_calls,
              toString(round(sum(total_exec_count * avg_exec_time_ms), 1)) AS total_exec_time_ms_estimate
            FROM query_intervals
            WHERE interval_ended_at BETWEEN parseDateTime64BestEffort('#{window.fetch("start_ts")}')
              AND parseDateTime64BestEffort('#{window.fetch("end_ts")}') + INTERVAL 90 SECOND
            GROUP BY queryid
            ORDER BY sum(total_exec_count * avg_exec_time_ms) DESC
            LIMIT #{CLICKHOUSE_TOPN_LIMIT}
          SQL
        end
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  Load::Workloads::MissingIndexTodos::Oracle.new.run(ARGV)
end
