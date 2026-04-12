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
    assert_match(/statement_text\s+Nullable\(String\)/, sql)
    assert_match(/total_exec_time_ms\s+Float64/, sql)
    assert_match(/ORDER BY \(dbid, userid, toplevel, queryid, collected_at\)/, sql)
    refute_match(/fingerprint\s+String/, sql)
    refute_match(/sample_query\s+Nullable\(String\)/, sql)
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
    assert_includes sql, "statement_text"
    assert_includes sql, "avg_exec_time_ms"
    refute_includes sql, "fingerprint"
    refute_includes sql, "sample_query"
  end

  def test_query_intervals_casts_delta_columns_to_clickhouse_24_compatible_types
    sql = read_sql("003_query_intervals.sql")

    assert_includes sql, "CAST(total_exec_time_ms - previous_total_exec_time_ms AS Float64)"
    assert_includes sql, "CAST(shared_blks_hit - previous_shared_blks_hit AS Int64)"
    assert_includes sql, "IF(delta_exec_count > 0, delta_exec_time_ms / delta_exec_count, NULL)"
    refute_includes sql, "mean_exec_time_ms"
  end

  def test_postgres_logs_schema_exists_with_raw_json_payload
    sql = read_sql("005_postgres_logs.sql")

    assert_match(/CREATE TABLE IF NOT EXISTS postgres_logs/, sql)
    assert_match(/query_id\s+String/, sql)
    assert_match(/statement_text\s+Nullable\(String\)/, sql)
    assert_match(/raw_json\s+String/, sql)
    assert_match(/ENGINE = ReplacingMergeTree/, sql)
    assert_match(/ORDER BY \(log_file, byte_offset\)/, sql)
  end

  def test_postgres_log_state_schema_exists_with_resume_offsets
    sql = read_sql("006_postgres_log_state.sql")

    assert_match(/CREATE TABLE IF NOT EXISTS postgres_log_state/, sql)
    assert_match(/log_file\s+String/, sql)
    assert_match(/byte_offset\s+UInt64/, sql)
    assert_match(/file_size_at_last_read\s+UInt64/, sql)
    assert_match(/collected_at\s+DateTime64\(3\)/, sql)
  end

  def test_reset_sql_rebuilds_raw_state_and_interval_objects
    sql = read_sql("004_reset_query_analytics.sql")

    assert_includes sql, "DROP VIEW IF EXISTS query_intervals"
    assert_includes sql, "DROP TABLE IF EXISTS postgres_log_state"
    assert_includes sql, "DROP TABLE IF EXISTS postgres_logs"
    assert_includes sql, "DROP TABLE IF EXISTS collector_state"
    assert_includes sql, "DROP TABLE IF EXISTS query_events"
    assert_includes sql, "CREATE TABLE query_events"
    assert_includes sql, "CREATE TABLE collector_state"
    assert_includes sql, "CREATE TABLE IF NOT EXISTS postgres_logs"
    assert_includes sql, "CREATE TABLE IF NOT EXISTS postgres_log_state"
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

  def test_reset_sql_matches_postgres_logs_definition
    canonical_sql = strip_header(read_sql("005_postgres_logs.sql"))
    reset_sql = strip_header(read_sql("004_reset_query_analytics.sql"))

    assert_includes reset_sql, canonical_sql
  end

  def test_reset_sql_matches_postgres_log_state_definition
    canonical_sql = strip_header(read_sql("006_postgres_log_state.sql"))
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
