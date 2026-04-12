# ABOUTME: Verifies ingestion of PostgreSQL JSON statement logs into ClickHouse rows.
# ABOUTME: Covers query filtering, source metadata parsing, query_id normalization, and partial reads.
require "minitest/autorun"
require "stringio"
require_relative "../lib/log_ingester"

class LogIngesterTest < Minitest::Test
  def test_ingests_only_complete_json_lines_with_query_id
    io = StringIO.new(<<~LOG)
      {"timestamp":"2026-04-12 12:00:00.000 UTC","query_id":-7,"statement":"SELECT 1 /*source_location:/app/models/todo.rb:5*/","session_id":"s1","dbname":"checkpoint_demo"}
      {"timestamp":"2026-04-12 12:00:01.000 UTC","message":"checkpoint starting"}
    LOG
    clickhouse = FakeClickhouseConnection.new
    state_store = FakeStateStore.new

    LogIngester.new(
      log_reader: ->(*) { io.read.to_s },
      clickhouse_connection: clickhouse,
      state_store: state_store,
      clock: -> { Time.utc(2026, 4, 12, 12, 0, 2) }
    ).ingest_file("postgresql.json")

    assert_equal "postgres_logs", clickhouse.table
    assert_equal 1, clickhouse.rows.length

    row = clickhouse.rows.fetch(0)

    assert_equal "postgresql.json", row[:log_file]
    assert_equal 0, row[:byte_offset]
    assert_equal Time.utc(2026, 4, 12, 12, 0, 0), row[:log_timestamp]
    assert_equal "-7", row[:query_id]
    assert_equal "SELECT 1 /*source_location:/app/models/todo.rb:5*/", row[:statement_text]
    assert_equal "checkpoint_demo", row[:database]
    assert_equal "s1", row[:session_id]
    assert_equal "/app/models/todo.rb:5", row[:source_location]
    assert_equal "{\"timestamp\":\"2026-04-12 12:00:00.000 UTC\",\"query_id\":-7,\"statement\":\"SELECT 1 /*source_location:/app/models/todo.rb:5*/\",\"session_id\":\"s1\",\"dbname\":\"checkpoint_demo\"}", row[:raw_json]
    assert_equal(
      {
        byte_offset: io.string.bytesize,
        file_size_at_last_read: io.string.bytesize,
        collected_at: Time.utc(2026, 4, 12, 12, 0, 2)
      },
      state_store.state_for("postgresql.json")
    )
  end

  def test_buffers_partial_trailing_line_until_next_read
    reads_by_offset = {
      0 => "{\"timestamp\":\"2026-04-12 12:00:00.000 UTC\",\"query_id\":1",
      55 => ",\"statement\":\"SELECT 1\"}\n"
    }
    observed_offsets = []
    clickhouse = FakeClickhouseConnection.new
    state_store = FakeStateStore.new

    ingester = LogIngester.new(
      log_reader: lambda do |_, byte_offset|
        observed_offsets << byte_offset
        reads_by_offset.fetch(byte_offset, "")
      end,
      clickhouse_connection: clickhouse,
      state_store: state_store,
      clock: -> { Time.utc(2026, 4, 12, 12, 0, 3) }
    )

    ingester.ingest_file("postgresql.json")

    assert_nil clickhouse.table
    assert_equal(
      {
        byte_offset: 0,
        file_size_at_last_read: 55,
        collected_at: Time.utc(2026, 4, 12, 12, 0, 3)
      },
      state_store.state_for("postgresql.json")
    )

    ingester.ingest_file("postgresql.json")

    assert_equal 1, clickhouse.rows.length
    assert_equal 0, clickhouse.rows.fetch(0).fetch(:byte_offset)
    assert_equal [0, 55], observed_offsets
    assert_equal(
      {
        byte_offset: 80,
        file_size_at_last_read: 80,
        collected_at: Time.utc(2026, 4, 12, 12, 0, 3)
      },
      state_store.state_for("postgresql.json")
    )
  end

  def test_restart_rereads_unfinished_trailing_line_from_last_complete_offset
    first_state_store = FakeStateStore.new

    LogIngester.new(
      log_reader: ->(*) { "{\"timestamp\":\"2026-04-12 12:00:00.000 UTC\",\"query_id\":1" },
      clickhouse_connection: FakeClickhouseConnection.new,
      state_store: first_state_store,
      clock: -> { Time.utc(2026, 4, 12, 12, 0, 3) }
    ).ingest_file("postgresql.json")

    clickhouse = FakeClickhouseConnection.new
    reread_offsets = []

    LogIngester.new(
      log_reader: lambda do |_, byte_offset|
        reread_offsets << byte_offset
        "{\"timestamp\":\"2026-04-12 12:00:00.000 UTC\",\"query_id\":1,\"statement\":\"SELECT 1\"}\n"
      end,
      clickhouse_connection: clickhouse,
      state_store: first_state_store,
      clock: -> { Time.utc(2026, 4, 12, 12, 0, 4) }
    ).ingest_file("postgresql.json")

    assert_equal [0], reread_offsets
    assert_equal 1, clickhouse.rows.length
    assert_equal 0, clickhouse.rows.fetch(0).fetch(:byte_offset)
  end

  def test_skips_malformed_json_lines_and_keeps_ingesting_later_lines
    log_lines = <<~LOG
      {"timestamp":"2026-04-12 12:00:00.000 UTC","query_id":1,"statement":"SELECT 1"}
      {"timestamp":"2026-04-12 12:00:01.000 UTC","query_id":
      {"timestamp":"2026-04-12 12:00:02.000 UTC","query_id":2,"statement":"SELECT 2"}
    LOG
    clickhouse = FakeClickhouseConnection.new
    state_store = FakeStateStore.new
    stderr = StringIO.new

    reads_by_offset = {
      0 => log_lines,
      log_lines.bytesize => "{\"timestamp\":\"2026-04-12 12:00:03.000 UTC\",\"query_id\":3,\"statement\":\"SELECT 3\"}\n"
    }
    observed_offsets = []

    ingester = LogIngester.new(
      log_reader: lambda do |_, byte_offset|
        observed_offsets << byte_offset
        reads_by_offset.fetch(byte_offset, "")
      end,
      clickhouse_connection: clickhouse,
      state_store: state_store,
      stderr: stderr
    )

    ingester.ingest_file("postgresql.json")

    assert_equal %w[1 2], clickhouse.rows.map { |row| row.fetch(:query_id) }
    assert_includes stderr.string, "Skipping malformed log line"
    assert_includes stderr.string, "postgresql.json"
    assert_equal log_lines.bytesize, state_store.state_for("postgresql.json").fetch(:byte_offset)
    assert_equal log_lines.bytesize, state_store.state_for("postgresql.json").fetch(:file_size_at_last_read)
    assert_instance_of Time, state_store.state_for("postgresql.json").fetch(:collected_at)

    ingester.ingest_file("postgresql.json")

    assert_equal [0, log_lines.bytesize], observed_offsets
    assert_equal ["3"], clickhouse.rows.map { |row| row.fetch(:query_id) }
  end

  def test_skips_lines_with_bad_timestamps_and_keeps_ingesting_later_lines
    log_lines = <<~LOG
      {"timestamp":"not-a-time","query_id":1,"statement":"SELECT 1"}
      {"timestamp":"2026-04-12 12:00:02.000 UTC","query_id":2,"statement":"SELECT 2"}
    LOG
    clickhouse = FakeClickhouseConnection.new
    state_store = FakeStateStore.new
    stderr = StringIO.new

    reads_by_offset = {
      0 => log_lines,
      log_lines.bytesize => "{\"timestamp\":\"2026-04-12 12:00:03.000 UTC\",\"query_id\":3,\"statement\":\"SELECT 3\"}\n"
    }
    observed_offsets = []

    ingester = LogIngester.new(
      log_reader: lambda do |_, byte_offset|
        observed_offsets << byte_offset
        reads_by_offset.fetch(byte_offset, "")
      end,
      clickhouse_connection: clickhouse,
      state_store: state_store,
      stderr: stderr
    )

    ingester.ingest_file("postgresql.json")

    assert_equal ["2"], clickhouse.rows.map { |row| row.fetch(:query_id) }
    assert_includes stderr.string, "Skipping malformed log line"
    assert_includes stderr.string, "not-a-time"
    assert_equal log_lines.bytesize, state_store.state_for("postgresql.json").fetch(:byte_offset)
    assert_equal log_lines.bytesize, state_store.state_for("postgresql.json").fetch(:file_size_at_last_read)

    ingester.ingest_file("postgresql.json")

    assert_equal [0, log_lines.bytesize], observed_offsets
    assert_equal ["3"], clickhouse.rows.map { |row| row.fetch(:query_id) }
  end

  def test_resets_offset_to_zero_when_file_shrinks_after_rotation
    log_line_before = "{\"timestamp\":\"2026-04-12 12:00:00.000 UTC\",\"query_id\":1,\"statement\":\"SELECT 1\"}\n"
    log_line_after  = "{\"timestamp\":\"2026-04-12 12:01:00.000 UTC\",\"query_id\":2,\"statement\":\"SELECT 2\"}\n"

    state_store = FakeStateStore.new
    # Simulate a previous ingestion run that left an offset at end of old file
    state_store.save("postgresql.json",
      byte_offset: log_line_before.bytesize,
      file_size_at_last_read: log_line_before.bytesize,
      collected_at: Time.utc(2026, 4, 12, 12, 0, 5))

    observed_offsets = []
    clickhouse = FakeClickhouseConnection.new

    # File has rotated: new file is shorter than the saved byte_offset
    ingester = LogIngester.new(
      log_reader: lambda do |_, byte_offset|
        observed_offsets << byte_offset
        byte_offset.zero? ? log_line_after : ""
      end,
      clickhouse_connection: clickhouse,
      state_store: state_store,
      # Simulated file size: new file is shorter than the saved offset
      file_sizer: ->(_) { log_line_before.bytesize - 10 }
    )

    ingester.ingest_file("postgresql.json")

    assert_equal [0], observed_offsets, "should reset to offset 0 after rotation"
    assert_equal ["2"], clickhouse.rows.map { |row| row.fetch(:query_id) }
  end

  def test_stringifies_large_numeric_query_ids
    log_line = <<~LOG
      {"timestamp":"2026-04-12 12:00:00.000 UTC","query_id":9223372036854775807,"statement":"SELECT 1"}
    LOG
    clickhouse = FakeClickhouseConnection.new

    LogIngester.new(
      log_reader: ->(*) { log_line },
      clickhouse_connection: clickhouse,
      state_store: FakeStateStore.new
    ).ingest_file("postgresql.json")

    assert_equal "9223372036854775807", clickhouse.rows.fetch(0).fetch(:query_id)
  end

  class FakeClickhouseConnection
    attr_reader :table, :rows

    def insert(table, rows)
      @table = table
      @rows = rows
    end
  end

  class FakeStateStore
    def initialize
      @state = {}
    end

    def load(log_file)
      @state[log_file]
    end

    def save(log_file, byte_offset:, file_size_at_last_read:, collected_at:)
      @state[log_file] = {
        byte_offset: byte_offset,
        file_size_at_last_read: file_size_at_last_read,
        collected_at: collected_at
      }
    end

    def state_for(log_file)
      @state[log_file]
    end
  end
end
