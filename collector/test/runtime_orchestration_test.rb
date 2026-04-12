# ABOUTME: Verifies the scheduled collector runtime orchestrates durable log ingestion and stats collection.
# ABOUTME: Covers restart-safe offset loading, per-pass connection refresh, and ingestion before snapshot querying.
require "minitest/autorun"
require "stringio"
load File.expand_path("../bin/collector", __dir__)

class RuntimeOrchestrationTest < Minitest::Test
  def test_run_once_pass_ingests_pending_logs_before_snapshot_querying_begins_with_fresh_connections
    events = []
    clickhouse_service = FakeClickhouseService.new(events: events)
    observed_offsets = []
    stats_connections = []
    clickhouse_connections = []
    log_line = <<~LOG
      {"timestamp":"2026-04-12 12:00:00.000 UTC","query_id":7,"statement":"SELECT 1"}
    LOG

    runtime = build_runtime(
      events: events,
      clickhouse_service: clickhouse_service,
      observed_offsets: observed_offsets,
      stats_connections: stats_connections,
      clickhouse_connections: clickhouse_connections,
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
      [:state_load, "postgresql.json"],
      [:insert, 1, "postgres_logs"],
      [:state_save, "postgresql.json", log_line.bytesize],
      [:stats_exec, 1, Collector::STATS_SQL],
      [:stats_exec, 1, Collector::INFO_SQL],
      [:insert, 1, "query_events"],
      [:stats_close, 1],
      [:state_load, "postgresql.json"],
      [:stats_exec, 2, Collector::STATS_SQL],
      [:stats_exec, 2, Collector::INFO_SQL],
      [:insert, 2, "query_events"],
      [:stats_close, 2],
    ], events
  end

  def test_runtime_resumes_ingestion_offsets_after_process_restart
    events = []
    clickhouse_service = FakeClickhouseService.new(events: events)
    observed_offsets = []
    log_line = "{\"timestamp\":\"2026-04-12 12:00:00.000 UTC\",\"query_id\":7,\"statement\":\"SELECT 1\"}\n"

    first_runtime = build_runtime(
      events: events,
      clickhouse_service: clickhouse_service,
      observed_offsets: observed_offsets,
      stats_connections: [],
      clickhouse_connections: [],
      log_reader: lambda do |_, byte_offset|
        observed_offsets << byte_offset
        byte_offset.zero? ? log_line : ""
      end,
    )
    first_runtime.run_once_pass

    second_runtime = build_runtime(
      events: events,
      clickhouse_service: clickhouse_service,
      observed_offsets: observed_offsets,
      stats_connections: [],
      clickhouse_connections: [],
      log_reader: lambda do |_, byte_offset|
        observed_offsets << byte_offset
        ""
      end,
    )
    second_runtime.run_once_pass

    assert_equal [0, log_line.bytesize], observed_offsets
  end

  private

  def build_runtime(events:, clickhouse_service:, observed_offsets:, stats_connections:, clickhouse_connections:, log_reader:)
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

    CollectorRuntime.new(
      interval_seconds: 5,
      postgres_url: "postgresql://postgres:postgres@postgres:5432/checkpoint_demo",
      clickhouse_url: "http://clickhouse:8123",
      log_file: "postgresql.json",
      clock: -> { Time.utc(2026, 4, 12, 12, 0, 5) },
      sleep_until: ->(*) {},
      stderr: StringIO.new,
      pg: pg,
      clickhouse_connection_class: clickhouse_connection_class,
      state_store_class: ClickhouseLogStateStore,
      state_store_transport: clickhouse_service.method(:call),
      log_reader: log_reader,
    )
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

    def exec(sql)
      @events << [:stats_exec, @id, sql]
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

  class FakeClickhouseService
    def initialize(events:)
      @events = events
      @state = {}
    end

    def call(uri, request)
      query = URI.decode_www_form(uri.query.to_s).to_h.fetch("query")

      if query.include?("SELECT byte_offset")
        log_file = query[/WHERE log_file = '([^']+)'/, 1]
        @events << [:state_load, log_file]
        state = @state[log_file]
        body = state ? "#{JSON.generate(stringify_state(state))}\n" : ""
        Response.new("200", body)
      elsif query.include?("INSERT INTO postgres_log_state FORMAT JSONEachRow")
        state = JSON.parse(request.body, symbolize_names: true)
        @state[state.fetch(:log_file)] = state
        @events << [:state_save, state.fetch(:log_file), state.fetch(:byte_offset)]
        Response.new("200", "")
      else
        raise "Unexpected ClickHouse request: #{query}"
      end
    end

    private

    def stringify_state(state)
      {
        log_file: state.fetch(:log_file),
        byte_offset: state.fetch(:byte_offset).to_s,
        file_size_at_last_read: state.fetch(:file_size_at_last_read).to_s,
        collected_at: state.fetch(:collected_at).to_s
      }
    end

    Response = Struct.new(:code, :body)
  end
end
