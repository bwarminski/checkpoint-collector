# ABOUTME: Verifies query_intervals view correctness against a live ClickHouse instance.
# ABOUTME: Guards baseline, valid delta, reset, and counter regression filter behavior.
require "json"
require "minitest/autorun"
require "net/http"
require "uri"

class ClickhouseIntervalViewTest < Minitest::Test
  CLICKHOUSE_URL = ENV["CLICKHOUSE_URL"]&.strip
  private_constant :CLICKHOUSE_URL

  def setup
    skip "Set CLICKHOUSE_URL to run ClickHouse integration tests" if CLICKHOUSE_URL.nil? || CLICKHOUSE_URL.empty?
    skip "CLICKHOUSE_URL not reachable" unless clickhouse_alive?

    exec_sql("DROP VIEW IF EXISTS query_intervals")
    exec_sql("DROP TABLE IF EXISTS postgres_log_state")
    exec_sql("DROP TABLE IF EXISTS postgres_logs")
    exec_sql("DROP TABLE IF EXISTS collector_state")
    exec_sql("DROP TABLE IF EXISTS query_events")
    exec_sql(strip_header(File.read(sql_path("001_query_events.sql"))))
    exec_sql(strip_header(File.read(sql_path("002_collector_state.sql"))))
    exec_sql(strip_header(File.read(sql_path("005_postgres_logs.sql"))))
    exec_sql(strip_header(File.read(sql_path("006_postgres_log_state.sql"))))
    exec_sql(strip_header(File.read(sql_path("003_query_intervals.sql"))))
  end

  def teardown
    return if CLICKHOUSE_URL.nil? || CLICKHOUSE_URL.empty?

    exec_sql("DROP VIEW IF EXISTS query_intervals")
    exec_sql("DROP TABLE IF EXISTS postgres_log_state")
    exec_sql("DROP TABLE IF EXISTS postgres_logs")
    exec_sql("DROP TABLE IF EXISTS collector_state")
    exec_sql("DROP TABLE IF EXISTS query_events")
  rescue StandardError
    nil
  end

  def test_first_snapshot_emits_no_interval_row
    insert_event(collected_at: "2026-04-10 12:00:00.000", queryid: "q1", statement_text: "SELECT 1", total_exec_count: 10, total_exec_time_ms: 100.0)
    insert_state(collected_at: "2026-04-10 12:00:00.000", stats_reset: "2026-04-10 11:00:00")

    assert_equal [], query_intervals("q1")
  end

  def test_second_snapshot_emits_delta_interval_row
    insert_event(collected_at: "2026-04-10 12:00:00.000", queryid: "q1", statement_text: "SELECT 1", total_exec_count: 10, total_exec_time_ms: 100.0)
    insert_event(collected_at: "2026-04-10 12:05:00.000", queryid: "q1", statement_text: "SELECT 1", total_exec_count: 15, total_exec_time_ms: 150.0)
    insert_state(collected_at: "2026-04-10 12:00:00.000", stats_reset: "2026-04-10 11:00:00")
    insert_state(collected_at: "2026-04-10 12:05:00.000", stats_reset: "2026-04-10 11:00:00")

    rows = query_intervals("q1")

    assert_equal 1, rows.length
    assert_equal 5, rows.first.fetch("total_exec_count").to_i
    assert_equal 50.0, rows.first.fetch("delta_exec_time_ms").to_f
    assert_equal 10.0, rows.first.fetch("avg_exec_time_ms").to_f
    assert_equal "SELECT 1", rows.first.fetch("statement_text")
    assert_equal({ "source_location" => "/app/models/todo.rb:5" }, rows.first.fetch("comment_metadata"))
  end

  def test_stats_reset_change_emits_no_interval_row
    insert_event(collected_at: "2026-04-10 12:00:00.000", queryid: "q1", statement_text: "SELECT 1", total_exec_count: 10, total_exec_time_ms: 100.0)
    insert_event(collected_at: "2026-04-10 12:05:00.000", queryid: "q1", statement_text: "SELECT 1", total_exec_count: 3, total_exec_time_ms: 30.0)
    insert_state(collected_at: "2026-04-10 12:00:00.000", stats_reset: "2026-04-10 11:00:00")
    insert_state(collected_at: "2026-04-10 12:05:00.000", stats_reset: "2026-04-10 12:04:00")

    assert_equal [], query_intervals("q1")
  end

  def test_counter_regression_emits_no_interval_row
    insert_event(collected_at: "2026-04-10 12:00:00.000", queryid: "q1", statement_text: "SELECT 1", total_exec_count: 10, total_exec_time_ms: 100.0)
    insert_event(collected_at: "2026-04-10 12:05:00.000", queryid: "q1", statement_text: "SELECT 1", total_exec_count: 5, total_exec_time_ms: 50.0)
    insert_state(collected_at: "2026-04-10 12:00:00.000", stats_reset: "2026-04-10 11:00:00")
    insert_state(collected_at: "2026-04-10 12:05:00.000", stats_reset: "2026-04-10 11:00:00")

    assert_equal [], query_intervals("q1")
  end

  def test_zero_delta_exec_count_emits_null_average_latency
    insert_event(collected_at: "2026-04-10 12:00:00.000", queryid: "q1", statement_text: "SELECT 1", total_exec_count: 10, total_exec_time_ms: 100.0)
    insert_event(collected_at: "2026-04-10 12:05:00.000", queryid: "q1", statement_text: "SELECT 1", total_exec_count: 10, total_exec_time_ms: 100.0)
    insert_state(collected_at: "2026-04-10 12:00:00.000", stats_reset: "2026-04-10 11:00:00")
    insert_state(collected_at: "2026-04-10 12:05:00.000", stats_reset: "2026-04-10 11:00:00")

    rows = query_intervals("q1")

    assert_equal 1, rows.length
    assert_nil rows.first.fetch("avg_exec_time_ms")
  end

  private

  def insert_event(collected_at:, queryid:, statement_text:, total_exec_count:, total_exec_time_ms:, dbid: 1, userid: 1, toplevel: true)
    exec_sql(<<~SQL)
      INSERT INTO query_events (
        collected_at, dbid, userid, toplevel, queryid, statement_text, comment_metadata,
        total_exec_count, total_exec_time_ms, rows_returned_or_affected,
        shared_blks_hit, shared_blks_read, local_blks_hit, local_blks_read,
        temp_blks_read, temp_blks_written, total_block_accesses,
        min_exec_time_ms, max_exec_time_ms, mean_exec_time_ms, stddev_exec_time_ms
      ) VALUES (
        '#{collected_at}', #{dbid}, #{userid}, #{toplevel ? 1 : 0}, '#{queryid}', '#{statement_text}', map('source_location', '/app/models/todo.rb:5'),
        #{total_exec_count}, #{total_exec_time_ms}, 0,
        0, 0, 0, 0,
        0, 0, 0,
        0, 0, 0, 0
      )
    SQL
  end

  def insert_state(collected_at:, stats_reset:, dealloc: 0)
    exec_sql(<<~SQL)
      INSERT INTO collector_state (collected_at, dealloc, stats_reset)
      VALUES ('#{collected_at}', #{dealloc}, '#{stats_reset}')
    SQL
  end

  def query_intervals(queryid = nil)
    sql = "SELECT * FROM query_intervals"
    sql += " WHERE queryid = '#{queryid}'" if queryid
    sql += " FORMAT JSONEachRow"

    request_sql(sql).strip.split("\n").reject(&:empty?).map do |line|
      JSON.parse(line)
    end
  end

  def clickhouse_alive?
    request_sql("SELECT 1")
    true
  rescue StandardError
    false
  end

  def exec_sql(sql)
    sql.split(/;\s*\n/).map(&:strip).reject(&:empty?).each do |statement|
      uri = URI("#{CLICKHOUSE_URL}/")
      request = Net::HTTP::Post.new(uri)
      request.body = statement

      response = Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
      next if response.code.to_i < 400

      raise "ClickHouse exec failed: #{response.code} #{response.body}"
    end
  end

  def request_sql(sql)
    uri = URI("#{CLICKHOUSE_URL}/?query=#{URI.encode_www_form_component(sql)}")
    response = Net::HTTP.get_response(uri)
    return response.body if response.code.to_i < 400

    raise "ClickHouse query failed: #{response.code} #{response.body}"
  end

  def sql_path(name)
    File.expand_path("../../db/clickhouse/#{name}", __dir__)
  end

  def strip_header(sql)
    sql.sub(/\A(?:--.*\n)+/, "")
  end
end
