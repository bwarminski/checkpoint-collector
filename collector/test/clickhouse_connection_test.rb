# ABOUTME: Verifies the collector can send query event rows to ClickHouse over HTTP.
# ABOUTME: Covers the JSONEachRow payload shape used by the runtime collector path.
require "minitest/autorun"
require "json"
require_relative "../lib/clickhouse_connection"
require_relative "support/env"

class ClickhouseConnectionTest < Minitest::Test
  def test_posts_json_each_row_insert_requests
    requests = []
    connection = ClickhouseConnection.new(
      base_url: "http://clickhouse:8123",
      transport: lambda do |uri, request|
        requests << { uri: uri, request: request }
        Struct.new(:code, :body).new("200", "")
      end
    )

    connection.insert("query_events", [{ fingerprint: "42", total_exec_count: 7 }])

    captured = requests.fetch(0)

    assert_equal "http://clickhouse:8123/?query=INSERT+INTO+query_events+FORMAT+JSONEachRow", captured[:uri].to_s
    assert_equal "POST", captured[:request].method
    assert_equal "{\"fingerprint\":\"42\",\"total_exec_count\":7}\n", captured[:request].body
  end

  def test_formats_time_values_for_clickhouse_datetime_columns
    requests = []
    connection = ClickhouseConnection.new(
      base_url: "http://clickhouse:8123",
      transport: lambda do |uri, request|
        requests << { uri: uri, request: request }
        Struct.new(:code, :body).new("200", "")
      end
    )

    connection.insert("query_events", [{ collected_at: Time.utc(2026, 4, 4, 14, 45, 0, 123_000) }])

    captured = requests.fetch(0)

    assert_equal "{\"collected_at\":\"2026-04-04 14:45:00.123\"}\n", captured[:request].body
  end
end
