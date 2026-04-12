# ABOUTME: Verifies the scheduled collector runtime orchestrates log ingestion and stats collection.
# ABOUTME: Covers per-pass connection refresh and ingestion ordering ahead of snapshot inserts.
require "minitest/autorun"
require "stringio"
load File.expand_path("../bin/collector", __dir__)

class RuntimeOrchestrationTest < Minitest::Test
  def test_run_once_pass_ingests_pending_logs_before_collecting_snapshot_rows_with_fresh_connections
    events = []
    observed_offsets = []
    state_store = LogStateStore.new
    stats_connections = []
    clickhouse_connections = []
    log_line = <<~LOG
      {"timestamp":"2026-04-12 12:00:00.000 UTC","query_id":7,"statement":"SELECT 1"}
    LOG

    pg = FakePg.new do |url|
      connection = StatsConnection.new(
        id: stats_connections.length + 1,
        url: url,
        events: events,
        stats_rows: [{ "queryid" => "7", "query" => "SELECT 1", "calls" => "1", "mean_exec_time" => "0.5" }],
        info_rows: [],
      )
      stats_connections << connection
      connection
    end

    clickhouse_connection_class = Class.new do
      define_singleton_method(:new) do |base_url:|
        connection = RecordingClickhouseConnection.new(
          id: clickhouse_connections.length + 1,
          base_url: base_url,
          events: events,
        )
        clickhouse_connections << connection
        connection
      end
    end

    runtime = CollectorRuntime.new(
      interval_seconds: 5,
      postgres_url: "postgresql://postgres:postgres@postgres:5432/checkpoint_demo",
      clickhouse_url: "http://clickhouse:8123",
      log_file: "postgresql.json",
      clock: -> { Time.utc(2026, 4, 12, 12, 0, 5) },
      sleep_until: ->(*) {},
      stderr: StringIO.new,
      pg: pg,
      clickhouse_connection_class: clickhouse_connection_class,
      state_store: state_store,
      log_reader: lambda do |_, byte_offset|
        observed_offsets << byte_offset
        byte_offset.zero? ? log_line : ""
      end,
    )

    runtime.run_once_pass
    runtime.run_once_pass

    assert_equal [0, log_line.bytesize], observed_offsets
    assert_equal 2, stats_connections.length
    assert_equal 2, clickhouse_connections.length
    refute_same stats_connections.first, stats_connections.last
    refute_same clickhouse_connections.first, clickhouse_connections.last
    assert_equal [
      [:insert, 1, "postgres_logs"],
      [:insert, 1, "query_events"],
      [:stats_close, 1],
      [:insert, 2, "query_events"],
      [:stats_close, 2],
    ], events
  end

  class FakePg
    def initialize(&factory)
      @factory = factory
    end

    def connect(url)
      @factory.call(url)
    end
  end

  class StatsConnection
    def initialize(id:, url:, events:, stats_rows:, info_rows:)
      @id = id
      @url = url
      @events = events
      @stats_rows = stats_rows
      @info_rows = info_rows
      @exec_count = 0
    end

    def exec(_sql)
      @exec_count += 1
      @exec_count == 1 ? @stats_rows : @info_rows
    end

    def close
      @events << [:stats_close, @id]
    end
  end

  class RecordingClickhouseConnection
    def initialize(id:, base_url:, events:)
      @id = id
      @base_url = base_url
      @events = events
    end

    def insert(table, rows)
      return if rows.empty?

      @events << [:insert, @id, table]
    end
  end
end
