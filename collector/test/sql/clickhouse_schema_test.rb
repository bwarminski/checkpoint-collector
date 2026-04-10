# ABOUTME: Verifies the ClickHouse schema files for raw query, state, and interval data.
# ABOUTME: Ensures reset SQL matches canonical raw tables and interval view definitions.
require "minitest/autorun"

class ClickhouseSchemaTest < Minitest::Test
  def test_query_events_store_snapshot_identity_and_counter_columns
    sql = read_sql("001_query_events.sql")

    assert_match(/dbid\s+UInt64/, sql)
    assert_match(/userid\s+UInt64/, sql)
    assert_match(/toplevel\s+Bool/, sql)
    assert_match(/queryid\s+String/, sql)
    assert_match(/total_exec_time_ms\s+Float64/, sql)
    assert_match(/ORDER BY \(dbid, userid, toplevel, queryid, collected_at\)/, sql)
    refute_match(/mean_block_accesses_per_call/, sql)
  end

  def test_collector_state_tracks_pg_stat_statements_info_snapshots
    sql = read_sql("002_collector_state.sql")

    assert_match(/dealloc\s+UInt64/, sql)
    assert_match(/stats_reset\s+DateTime/, sql)
  end

  def test_query_intervals_is_a_view_over_raw_snapshots
    sql = read_sql("003_query_intervals.sql")

    assert_match(/CREATE VIEW query_intervals AS/, sql)
    assert_includes sql, "interval_started_at"
    assert_includes sql, "interval_ended_at"
    assert_includes sql, "interval_duration_ms"
    assert_includes sql, "lagInFrame(e.total_exec_count)"
  end

  def test_query_intervals_casts_delta_columns_to_clickhouse_24_compatible_types
    sql = read_sql("003_query_intervals.sql")

    assert_includes sql, "CAST(total_exec_time_ms - previous_total_exec_time_ms AS Float64)"
    assert_includes sql, "CAST(shared_blks_hit - previous_shared_blks_hit AS Int64)"
  end

  def test_reset_sql_rebuilds_raw_state_and_interval_objects
    sql = read_sql("004_reset_query_analytics.sql")

    assert_includes sql, "DROP VIEW IF EXISTS query_intervals"
    assert_includes sql, "DROP TABLE IF EXISTS collector_state"
    assert_includes sql, "DROP TABLE IF EXISTS query_events"
    assert_includes sql, "CREATE TABLE query_events"
    assert_includes sql, "CREATE TABLE collector_state"
    assert_includes sql, "CREATE VIEW query_intervals"
  end

  def test_reset_sql_matches_query_events_definition
    canonical_sql = strip_header(read_sql("001_query_events.sql"))
    reset_sql = strip_header(read_sql("004_reset_query_analytics.sql"))

    assert_includes reset_sql, canonical_sql
  end

  def test_reset_sql_matches_collector_state_definition
    canonical_sql = strip_header(read_sql("002_collector_state.sql"))
    reset_sql = strip_header(read_sql("004_reset_query_analytics.sql"))

    assert_includes reset_sql, canonical_sql
  end

  def test_reset_sql_matches_query_intervals_definition
    canonical_sql = strip_header(read_sql("003_query_intervals.sql"))
    reset_sql = strip_header(read_sql("004_reset_query_analytics.sql"))

    assert_includes reset_sql, canonical_sql
  end

  def test_stale_aggregate_layer_files_are_removed
    refute File.exist?(File.expand_path("../../db/clickhouse/004_query_fingerprints.sql", __dir__))
    refute File.exist?(File.expand_path("../../db/clickhouse/005_top_offenders_mv.sql", __dir__))
    refute File.exist?(File.expand_path("../../db/clickhouse/006_reset_query_analytics.sql", __dir__))
  end

  private

  def read_sql(name)
    File.read(File.expand_path("../../db/clickhouse/#{name}", __dir__))
  end

  def strip_header(sql)
    sql.sub(/\A(?:--.*\n)+/, "")
  end
end
