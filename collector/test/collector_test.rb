# ABOUTME: Verifies one-shot collection from Postgres stats into query event rows.
# ABOUTME: Covers empty polling results and the ClickHouse payload shape for inserts.
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/collector"
require_relative "support/env"

class CollectorTest < Minitest::Test
  def test_env_loader_preserves_exported_values
    Dir.mktmpdir do |dir|
      env_path = File.join(dir, ".env")
      File.write(env_path, "DEMO_REPO=file/value\nDEMO_BASE_REF=main\n")

      previous_demo_repo = ENV["DEMO_REPO"]
      previous_demo_base_ref = ENV["DEMO_BASE_REF"]
      ENV["DEMO_REPO"] = "shell/value"
      ENV.delete("DEMO_BASE_REF")

      begin
        load_env_file(env_path)

        assert_equal "shell/value", ENV["DEMO_REPO"]
        assert_equal "main", ENV["DEMO_BASE_REF"]
      ensure
        restore_env("DEMO_REPO", previous_demo_repo)
        restore_env("DEMO_BASE_REF", previous_demo_base_ref)
      end
    end
  end

  def test_env_loader_uses_simple_split_and_skips_comments
    Dir.mktmpdir do |dir|
      env_path = File.join(dir, ".env")
      File.write(
        env_path,
        [
          "# comment",
          "",
          "A=one=two",
          "B=plain value",
        ].join("\n"),
      )

      %w[A B].each { |key| ENV.delete(key) }

      load_env_file(env_path)

      assert_equal "one=two", ENV["A"]
      assert_equal "plain value", ENV["B"]
    end
  end

  def test_returns_empty_array_when_no_stats_rows_exist
    stats_connection = StatsConnection.new([])
    clickhouse_connection = ClickhouseConnection.new
    collector = Collector.new(
      stats_connection: stats_connection,
      clickhouse_connection: clickhouse_connection,
      clock: -> { Time.utc(2026, 4, 4, 12, 0, 0) }
    )

    assert_equal [], collector.run_once
    assert_nil clickhouse_connection.table
    assert_nil clickhouse_connection.rows
  end

  def test_inserts_query_event_rows_with_source_metadata
    stats_connection = StatsConnection.new([
      {
        "queryid" => "42",
        "query" => "SELECT * FROM todos /*application:demo,controller:todos,action:index,source_location:/app/controllers/todos_controller.rb:12*/",
        "calls" => "7",
        "mean_exec_time" => "12.5",
        "rows" => "0",
        "shared_blks_hit" => "0",
        "shared_blks_read" => "0",
        "local_blks_hit" => "0",
        "local_blks_read" => "0",
        "temp_blks_read" => "0",
        "temp_blks_written" => "0"
      }
    ])
    clickhouse_connection = ClickhouseConnection.new
    collector = Collector.new(
      stats_connection: stats_connection,
      clickhouse_connection: clickhouse_connection,
      clock: -> { Time.utc(2026, 4, 4, 12, 0, 0) }
    )

    rows = collector.run_once

    expected_rows = [
      {
        collected_at: Time.utc(2026, 4, 4, 12, 0, 0),
        dbid: 0,
        userid: 0,
        toplevel: false,
        queryid: "42",
        statement_text: "SELECT * FROM todos /*application:demo,controller:todos,action:index,source_location:/app/controllers/todos_controller.rb:12*/",
        comment_metadata: {
          "application" => "demo",
          "controller" => "todos",
          "action" => "index",
          "source_location" => "/app/controllers/todos_controller.rb:12"
        },
        total_exec_count: 7,
        total_exec_time_ms: 0.0,
        min_exec_time_ms: 0.0,
        max_exec_time_ms: 0.0,
        mean_exec_time_ms: 12.5,
        stddev_exec_time_ms: 0.0,
        rows_returned_or_affected: 0,
        shared_blks_hit: 0,
        shared_blks_read: 0,
        local_blks_hit: 0,
        local_blks_read: 0,
        temp_blks_read: 0,
        temp_blks_written: 0,
        total_block_accesses: 0
      }
    ]

    assert_equal expected_rows, rows
    assert_equal "query_events", clickhouse_connection.table
    assert_equal expected_rows, clickhouse_connection.rows
  end

  def test_collector_inserts_comment_metadata_hash
    stats_row = {
      "queryid" => "42",
      "query" => "SELECT * FROM todos /*application:demo,controller:todos,action:index*/",
      "calls" => "1",
      "total_exec_time" => "1.0",
      "mean_exec_time" => "1.0"
    }
    stats_connection = StatsConnection.new([
      stats_row
    ])

    row = Collector.new(
      stats_connection: stats_connection,
      clock: -> { Time.utc(2026, 4, 12, 12, 0, 0) }
    ).send(:build_row, stats_row, Time.utc(2026, 4, 12, 12, 0, 0))

    assert_equal(
      { "application" => "demo", "controller" => "todos", "action" => "index" },
      row[:comment_metadata]
    )
    refute row.key?(:source_file)
  end

  def test_inserts_query_event_rows_with_statement_text_and_no_sample_columns
    stats_connection = StatsConnection.new([
      {
        "queryid" => "42",
        "query" => "SELECT * FROM todos WHERE id = $1",
        "calls" => "7",
        "total_exec_time" => "125.5",
        "mean_exec_time" => "17.9",
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
        "total_exec_time" => "1.0",
        "mean_exec_time" => "1.0"
      }
    ])

    row = Collector.new(
      stats_connection: stats_connection,
      clock: -> { Time.utc(2026, 4, 12, 12, 5, 0) }
    ).run_once.fetch(0)

    assert_nil row[:statement_text]
  end

  def test_run_once_captures_row_and_block_metrics
    stats_connection = StatsConnection.new([
      {
        "queryid" => "123",
        "calls" => "10",
        "mean_exec_time" => "15.5",
        "rows" => "2500",
        "shared_blks_hit" => "100",
        "shared_blks_read" => "40",
        "local_blks_hit" => "20",
        "local_blks_read" => "5",
        "temp_blks_read" => "3",
        "temp_blks_written" => "2"
      }
    ])
    collector = Collector.new(
      stats_connection: stats_connection,
      clock: -> { Time.utc(2026, 4, 5, 12, 0, 0) }
    )

    row = collector.run_once.first

    assert_equal 2500, row[:rows_returned_or_affected]
    assert_equal 100, row[:shared_blks_hit]
    assert_equal 40, row[:shared_blks_read]
    assert_equal 20, row[:local_blks_hit]
    assert_equal 5, row[:local_blks_read]
    assert_equal 3, row[:temp_blks_read]
    assert_equal 2, row[:temp_blks_written]
    assert_equal 170, row[:total_block_accesses]
    assert_equal Collector::STATS_SQL, stats_connection.sql_calls.fetch(0)
  end

  def test_run_once_does_not_emit_mean_block_accesses_per_call
    stats_connection = StatsConnection.new([
      {
        "queryid" => "123",
        "calls" => "10",
        "mean_exec_time" => "15.5",
        "rows" => "2500",
        "shared_blks_hit" => "100",
        "shared_blks_read" => "40",
        "local_blks_hit" => "20",
        "local_blks_read" => "5",
        "temp_blks_read" => "3",
        "temp_blks_written" => "2"
      }
    ])
    collector = Collector.new(
      stats_connection: stats_connection,
      clock: -> { Time.utc(2026, 4, 5, 12, 0, 0) }
    )

    row = collector.run_once.first

    refute row.key?(:mean_block_accesses_per_call)
  end

  def test_run_once_emits_exec_shape_columns_defined_by_query_events_schema
    stats_connection = StatsConnection.new([
      {
        "dbid" => "5",
        "userid" => "9",
        "toplevel" => "t",
        "queryid" => "42",
        "calls" => "7",
        "total_exec_time" => "125.5",
        "min_exec_time" => "10.0",
        "max_exec_time" => "30.0",
        "mean_exec_time" => "17.9",
        "stddev_exec_time" => "8.4"
      }
    ])

    row = Collector.new(
      stats_connection: stats_connection,
      clock: -> { Time.utc(2026, 4, 9, 12, 5, 0) }
    ).run_once.first

    assert_equal 10.0, row[:min_exec_time_ms]
    assert_equal 30.0, row[:max_exec_time_ms]
    assert_equal 17.9, row[:mean_exec_time_ms]
    assert_equal 8.4, row[:stddev_exec_time_ms]
  end

  def test_uses_only_the_rails_metadata_block_when_query_has_multiple_comments
    stats_connection = StatsConnection.new([
      {
        "queryid" => "42",
        "query" => "SELECT * FROM todos /*hint:seqscan_off*/ /*application:demo,controller:todos,action:index,source_location:/app/controllers/todos_controller.rb:12*/ /*note:trailing*/",
        "calls" => "7",
        "mean_exec_time" => "12.5"
      }
    ])
    clickhouse_connection = ClickhouseConnection.new
    collector = Collector.new(
      stats_connection: stats_connection,
      clickhouse_connection: clickhouse_connection,
      clock: -> { Time.utc(2026, 4, 4, 12, 0, 0) }
    )

    row = collector.run_once.fetch(0)

    assert_equal(
      {
        "hint" => "seqscan_off",
        "application" => "demo",
        "controller" => "todos",
        "action" => "index",
        "source_location" => "/app/controllers/todos_controller.rb:12",
        "note" => "trailing"
      },
      row[:comment_metadata]
    )
  end

  def test_prefers_block_with_source_location_over_controller_only_comment
    stats_connection = StatsConnection.new([
      {
        "queryid" => "42",
        "query" => "SELECT * FROM todos /*controller:todos,action:index*/ /*source_location:/app/controllers/todos_controller.rb:14*/",
        "calls" => "7",
        "mean_exec_time" => "12.5"
      }
    ])
    clickhouse_connection = ClickhouseConnection.new
    collector = Collector.new(
      stats_connection: stats_connection,
      clickhouse_connection: clickhouse_connection,
      clock: -> { Time.utc(2026, 4, 4, 12, 0, 0) }
    )

    row = collector.run_once.fetch(0)

    assert_equal(
      {
        "controller" => "todos",
        "action" => "index",
        "source_location" => "/app/controllers/todos_controller.rb:14"
      },
      row[:comment_metadata]
    )
  end

  def test_handles_live_rails_equals_style_comments_without_source_location
    stats_connection = StatsConnection.new([
      {
        "queryid" => "42",
        "query" => "SELECT * FROM todos /*action=\\'index\\',application=\\'Demo\\',controller=\\'todos\\'*/",
        "calls" => "7",
        "mean_exec_time" => "12.5"
      }
    ])
    clickhouse_connection = ClickhouseConnection.new
    collector = Collector.new(
      stats_connection: stats_connection,
      clickhouse_connection: clickhouse_connection,
      clock: -> { Time.utc(2026, 4, 4, 12, 0, 0) }
    )

    row = collector.run_once.fetch(0)

    assert_equal(
      {
        "action" => "index",
        "application" => "Demo",
        "controller" => "todos"
      },
      row[:comment_metadata]
    )
  end

  def test_inserts_counter_snapshots_into_query_events_and_collector_state
    stats_connection = StatsConnection.new(
      stats_rows: [
        {
          "dbid" => "5",
          "userid" => "9",
          "toplevel" => "t",
          "queryid" => "42",
          "query" => "SELECT 1 /*source_location:/app/models/todo.rb:7*/",
          "calls" => "7",
          "total_exec_time" => "125.5",
          "min_exec_time" => "10.0",
          "max_exec_time" => "30.0",
          "mean_exec_time" => "17.9",
          "stddev_exec_time" => "8.4",
          "rows" => "20",
          "shared_blks_hit" => "100",
          "shared_blks_read" => "40",
          "local_blks_hit" => "3",
          "local_blks_read" => "2",
          "temp_blks_read" => "1",
          "temp_blks_written" => "4"
        }
      ],
      info_rows: [{ "dealloc" => "3", "stats_reset" => "2026-04-09 12:00:00+00" }],
    )
    clickhouse_connection = RecordingClickhouseConnection.new
    collector = Collector.new(
      stats_connection: stats_connection,
      clickhouse_connection: clickhouse_connection,
      clock: -> { Time.utc(2026, 4, 9, 12, 5, 0) }
    )

    rows = collector.run_once

    assert_equal 1, rows.length
    assert_equal 5, rows.first[:dbid]
    assert_equal 9, rows.first[:userid]
    assert_equal true, rows.first[:toplevel]
    assert_equal "42", rows.first[:queryid]
    assert_equal 125.5, rows.first[:total_exec_time_ms]
    assert_equal 150, rows.first[:total_block_accesses]
    assert_equal [
      ["query_events", rows],
      ["collector_state", [{ collected_at: Time.utc(2026, 4, 9, 12, 5, 0), dealloc: 3, stats_reset: "2026-04-09 12:00:00" }]],
    ], clickhouse_connection.inserts
  end

  def test_run_once_uses_widened_stats_and_info_queries
    stats_connection = StatsConnection.new(stats_rows: [], info_rows: [])
    collector = Collector.new(stats_connection: stats_connection)

    collector.run_once

    assert_equal Collector::STATS_SQL, stats_connection.sql_calls.fetch(0)
    assert_equal Collector::INFO_SQL, stats_connection.sql_calls.fetch(1)
  end

  def test_inserts_collector_state_when_info_row_exists_without_stats_rows
    stats_connection = StatsConnection.new(
      stats_rows: [],
      info_rows: [{ "dealloc" => "8", "stats_reset" => "2026-04-09 12:30:00+00" }],
    )
    clickhouse_connection = RecordingClickhouseConnection.new
    collector = Collector.new(
      stats_connection: stats_connection,
      clickhouse_connection: clickhouse_connection,
      clock: -> { Time.utc(2026, 4, 9, 12, 45, 0) }
    )

    rows = collector.run_once

    assert_equal [], rows
    assert_equal [
      ["collector_state", [{ collected_at: Time.utc(2026, 4, 9, 12, 45, 0), dealloc: 8, stats_reset: "2026-04-09 12:30:00" }]],
    ], clickhouse_connection.inserts
  end

  def test_formats_stats_reset_as_clickhouse_datetime_string
    stats_connection = StatsConnection.new(
      stats_rows: [],
      info_rows: [{ "dealloc" => "0", "stats_reset" => "2026-04-09 12:00:00.055815+00" }],
    )
    clickhouse_connection = RecordingClickhouseConnection.new
    collector = Collector.new(
      stats_connection: stats_connection,
      clickhouse_connection: clickhouse_connection,
      clock: -> { Time.utc(2026, 4, 9, 12, 5, 0) }
    )

    collector.run_once

    state_row = clickhouse_connection.inserts.first.last.first
    assert_equal "2026-04-09 12:00:00", state_row[:stats_reset]
  end

  class StatsConnection
    attr_reader :sql, :sql_calls

    def initialize(rows = nil, stats_rows: nil, info_rows: nil)
      @rows = rows
      @stats_rows = stats_rows
      @info_rows = info_rows
      @sql_calls = []
    end

    def exec(sql)
      @sql = sql
      @sql_calls << sql
      if @sql_calls.length == 1 && !@stats_rows.nil?
        @stats_rows
      elsif @sql_calls.length == 2 && !@info_rows.nil?
        @info_rows
      elsif @sql_calls.length == 2
        []
      else
        @rows
      end
    end
  end

  class ClickhouseConnection
    attr_reader :table, :rows

    def insert(table, rows)
      @table = table
      @rows = rows
    end
  end

  class RecordingClickhouseConnection
    attr_reader :inserts

    def initialize
      @inserts = []
    end

    def insert(table, rows)
      @inserts << [table, rows]
    end
  end

  def restore_env(key, value)
    if value.nil?
      ENV.delete(key)
    else
      ENV[key] = value
    end
  end
end
