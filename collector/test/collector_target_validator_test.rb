# ABOUTME: Verifies collector target validation before local or PlanetScale soak runs.
# ABOUTME: Uses fake Postgres, ClickHouse, and runtime seams to test failure contracts.
require "minitest/autorun"
require_relative "../lib/collector_target_validator"

class CollectorTargetValidatorTest < Minitest::Test
  VALIDATION_QUERYIDS_SQL = <<~SQL.freeze
    SELECT DISTINCT queryid::text AS queryid
    FROM pg_stat_statements
    WHERE query = 'SELECT current_setting($1) /* collector_target_validation */'
  SQL

  def test_call_runs_marker_query_and_requires_fresh_clickhouse_evidence
    pg = FakePg.new(queryid_rows: [{ "queryid" => "6865378226349601843" }])
    runtime_calls = []
    captured_sql = []
    scalar_values = {
      "collector_state" => [10, 11],
      "query_events" => [20, 21],
    }
    validator = build_validator(
      pg:,
      runtime_factory: ->(**kwargs) { runtime_calls << kwargs; FakeRuntime.new },
      clickhouse_query: scalar_query(scalar_values, captured_sql:),
    )

    result = validator.call

    assert_equal true, result.fetch("ok")
    assert_equal 10, result.fetch("collector_state_before")
    assert_equal 11, result.fetch("collector_state_after")
    assert_equal 20, result.fetch("query_events_before")
    assert_equal 21, result.fetch("query_events_after")
    assert_equal ["postgres://example.test/checkpoint", "postgres://example.test/checkpoint", "postgres://example.test/checkpoint"], pg.urls
    assert_includes pg.connections.fetch(0).sql, CollectorTargetValidator::PG_STAT_STATEMENTS_CHECK_SQL
    assert_includes pg.connections.fetch(1).sql, CollectorTargetValidator::VALIDATION_SQL
    assert_includes pg.connections.fetch(2).sql, VALIDATION_QUERYIDS_SQL
    assert captured_sql.grep(/queryid IN \('6865378226349601843'\)/).any?,
      "expected ClickHouse validation to filter by resolved queryid, got #{captured_sql.inspect}"
    refute captured_sql.any? { |sql| sql.include?(CollectorTargetValidator::VALIDATION_COMMENT) },
      "pg_stat_statements strips SQL comments, so ClickHouse validation must not depend on them"
    assert_equal [{ postgres_url: "postgres://example.test/checkpoint", clickhouse_url: "http://clickhouse:8123" }], runtime_calls
  end

  def test_call_rejects_missing_postgres_url
    validator = build_validator(postgres_url: nil)

    error = assert_raises(CollectorTargetValidator::Error) { validator.call }

    assert_equal "POSTGRES_URL is required", error.message
  end

  def test_call_rejects_missing_clickhouse_url
    validator = build_validator(clickhouse_url: nil)

    error = assert_raises(CollectorTargetValidator::Error) { validator.call }

    assert_equal "CLICKHOUSE_URL is required", error.message
  end

  def test_call_requires_stats_only_mode_when_requested
    validator = build_validator(require_stats_only: true, env: {})

    error = assert_raises(CollectorTargetValidator::Error) { validator.call }

    assert_equal "stats-only collector validation requires COLLECTOR_DISABLE_LOG_INGESTION=1", error.message
  end

  def test_call_reports_unreadable_pg_stat_statements
    pg = FakePg.new(error_on: CollectorTargetValidator::PG_STAT_STATEMENTS_CHECK_SQL)
    validator = build_validator(pg:)

    error = assert_raises(CollectorTargetValidator::Error) { validator.call }

    assert_match(/pg_stat_statements is not readable: blocked/, error.message)
  end

  def test_call_requires_collector_state_to_advance
    scalar_values = {
      "collector_state" => [10, 10],
      "query_events" => [20, 21],
    }
    validator = build_validator(clickhouse_query: scalar_query(scalar_values))

    error = assert_raises(CollectorTargetValidator::Error) { validator.call }

    assert_equal "collector_state did not advance", error.message
  end

  def test_call_requires_marker_query_evidence_to_advance
    scalar_values = {
      "collector_state" => [10, 11],
      "query_events" => [20, 20],
    }
    validator = build_validator(clickhouse_query: scalar_query(scalar_values))

    error = assert_raises(CollectorTargetValidator::Error) { validator.call }

    assert_equal "query_events did not capture collector_target_validation", error.message
  end

  private

  def build_validator(
    postgres_url: "postgres://example.test/checkpoint",
    clickhouse_url: "http://clickhouse:8123",
    require_stats_only: false,
    env: {},
    pg: FakePg.new,
    runtime_factory: ->(**) { FakeRuntime.new },
    clickhouse_query: scalar_query({ "collector_state" => [1, 2], "query_events" => [1, 2] })
  )
    CollectorTargetValidator.new(
      postgres_url:,
      clickhouse_url:,
      require_stats_only:,
      env:,
      pg:,
      runtime_factory:,
      clickhouse_query:,
    )
  end

  def scalar_query(values, captured_sql: [])
    lambda do |clickhouse_url:, sql:|
      captured_sql << sql
      key = sql.include?("collector_state") ? "collector_state" : "query_events"
      values.fetch(key).shift
    end
  end

  class FakeRuntime
    def run_once_pass
      true
    end
  end

  class FakePg
    attr_reader :connections, :urls

    def initialize(error_on: nil, queryid_rows: [{ "queryid" => "6865378226349601843" }])
      @error_on = error_on
      @queryid_rows = queryid_rows
      @connections = []
      @urls = []
    end

    def connect(url)
      @urls << url
      connection = FakeConnection.new(error_on: @error_on, queryid_rows: @queryid_rows)
      @connections << connection
      connection
    end
  end

  class FakeConnection
    attr_reader :sql

    def initialize(error_on:, queryid_rows:)
      @error_on = error_on
      @queryid_rows = queryid_rows
      @sql = []
    end

    def exec(sql)
      @sql << sql
      raise "blocked" if sql == @error_on
      return @queryid_rows if sql == CollectorTargetValidatorTest::VALIDATION_QUERYIDS_SQL

      []
    end

    def close
      true
    end
  end
end
