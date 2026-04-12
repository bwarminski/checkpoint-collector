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
    reads = [
      "{\"timestamp\":\"2026-04-12 12:00:00.000 UTC\",\"query_id\":1",
      ",\"statement\":\"SELECT 1\"}\n"
    ]
    clickhouse = FakeClickhouseConnection.new
    state_store = FakeStateStore.new

    ingester = LogIngester.new(
      log_reader: ->(*) { reads.shift.to_s },
      clickhouse_connection: clickhouse,
      state_store: state_store,
      clock: -> { Time.utc(2026, 4, 12, 12, 0, 3) }
    )

    ingester.ingest_file("postgresql.json")

    assert_nil clickhouse.table
    assert_equal(
      {
        byte_offset: 55,
        file_size_at_last_read: 55,
        collected_at: Time.utc(2026, 4, 12, 12, 0, 3)
      },
      state_store.state_for("postgresql.json")
    )

    ingester.ingest_file("postgresql.json")

    assert_equal 1, clickhouse.rows.length
    assert_equal 0, clickhouse.rows.fetch(0).fetch(:byte_offset)
    assert_equal(
      {
        byte_offset: 80,
        file_size_at_last_read: 80,
        collected_at: Time.utc(2026, 4, 12, 12, 0, 3)
      },
      state_store.state_for("postgresql.json")
    )
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
