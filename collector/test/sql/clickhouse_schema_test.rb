# ABOUTME: Verifies the ClickHouse schema files for the query collector.
# ABOUTME: Guards the materialized view definition against embedding ORDER BY.
require "minitest/autorun"

class ClickhouseSchemaTest < Minitest::Test
  def test_query_events_store_snapshot_identity_and_counter_columns
    sql = read_sql("001_query_events.sql")

    assert_match(/dbid\s+UInt64/, sql)
    assert_match(/userid\s+UInt64/, sql)
    assert_match(/toplevel\s+Bool/, sql)
    assert_match(/queryid\s+String/, sql)
    assert_match(/total_exec_time_ms\s+Float64/, sql)
    refute_match(/mean_block_accesses_per_call/, sql)
  end

  def test_collector_state_tracks_pg_stat_statements_info_snapshots
    sql = read_sql("002_collector_state.sql")

    assert_match(/dealloc\s+UInt64/, sql)
    assert_match(/stats_reset\s+DateTime/, sql)
  end

  def test_query_intervals_capture_reset_aware_deltas
    sql = read_sql("003_query_intervals.sql")

    assert_includes sql, "interval_started_at"
    assert_includes sql, "interval_ended_at"
    assert_includes sql, "interval_duration_ms"
    assert_includes sql, "lagInFrame(total_exec_count)"
  end

  def test_findings_view_aggregates_from_query_intervals
    sql = read_sql("005_top_offenders_mv.sql")

    assert_match(/FROM query_intervals/, sql)
    assert_match(/GROUP BY fingerprint/, sql)
    assert_includes sql, "quantileState(0.95)(delta_exec_time_ms)"
  end

  private

  def read_sql(name)
    File.read(File.expand_path("../../db/clickhouse/#{name}", __dir__))
  end
end
