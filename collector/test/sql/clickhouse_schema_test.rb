# ABOUTME: Verifies the ClickHouse schema files for the query collector.
# ABOUTME: Guards the materialized view definition against embedding ORDER BY.
require "minitest/autorun"

class ClickhouseSchemaTest < Minitest::Test
  def test_materialized_view_groups_by_fingerprint
    sql = read_sql("003_top_offenders_mv.sql")

    refute_match(/\bORDER BY\b/i, sql)
    assert_includes sql, "CREATE MATERIALIZED VIEW"
    refute_match(/\banyState\b/i, sql)
    assert_includes sql, "argMaxState((source_file, sample_query), collected_at) AS representative_state"
    assert_includes sql, "sumState(total_exec_count * mean_exec_time_ms) AS total_exec_time_ms_state"
    assert_includes sql, "GROUP BY fingerprint"
  end

  def test_fingerprint_table_groups_by_fingerprint
    sql = read_sql("002_query_fingerprints.sql")

    refute_includes sql, "source_tag"
    assert_includes sql, "representative_state AggregateFunction(argMax, Tuple(Nullable(String), Nullable(String)), DateTime64(3))"
    assert_includes sql, "total_exec_time_ms_state AggregateFunction(sum, Float64)"
    assert_includes sql, "ORDER BY (fingerprint)"
  end

  def test_reset_sql_rebuilds_query_fingerprints_with_block_state
    sql = read_sql("004_reset_query_fingerprints.sql")

    refute_includes sql, "source_tag"
    assert_includes sql, "Run this only while collector ingestion is stopped so no raw events are missed."
    assert_includes sql, "DROP TABLE IF EXISTS top_offenders_mv"
    assert_includes sql, "DROP TABLE IF EXISTS query_fingerprints"
    assert_includes sql, "CREATE TABLE query_fingerprints"
    assert_includes sql, "INSERT INTO query_fingerprints"
    assert_includes sql, "argMaxState((source_file, sample_query), collected_at) AS representative_state"
    assert_includes sql, "sumState(rows_returned_or_affected) AS rows_returned_or_affected_state"
    assert_includes sql, "sumState(shared_blks_hit) AS shared_blks_hit_state"
    assert_includes sql, "sumState(shared_blks_read) AS shared_blks_read_state"
    assert_includes sql, "sumState(local_blks_hit) AS local_blks_hit_state"
    assert_includes sql, "sumState(local_blks_read) AS local_blks_read_state"
    assert_includes sql, "sumState(temp_blks_read) AS temp_blks_read_state"
    assert_includes sql, "sumState(temp_blks_written) AS temp_blks_written_state"
    assert_includes sql, "sumState(total_block_accesses) AS total_block_accesses_state"
    assert_includes sql, "CREATE MATERIALIZED VIEW top_offenders_mv"
  end

  def test_query_events_store_subsecond_collection_times
    sql = read_sql("001_query_events.sql")

    assert_includes sql, "collected_at DateTime64(3)"
  end

  def test_query_events_and_fingerprints_track_row_and_block_metrics
    query_events_sql = read_sql("001_query_events.sql")
    fingerprints_sql = read_sql("002_query_fingerprints.sql")
    mv_sql = read_sql("003_top_offenders_mv.sql")

    assert_match(/rows_returned_or_affected\s+UInt64/, query_events_sql)
    assert_match(/shared_blks_hit\s+UInt64/, query_events_sql)
    assert_match(/shared_blks_read\s+UInt64/, query_events_sql)
    assert_match(/local_blks_hit\s+UInt64/, query_events_sql)
    assert_match(/local_blks_read\s+UInt64/, query_events_sql)
    assert_match(/temp_blks_read\s+UInt64/, query_events_sql)
    assert_match(/temp_blks_written\s+UInt64/, query_events_sql)
    assert_match(/total_block_accesses\s+UInt64/, query_events_sql)
    assert_match(/mean_block_accesses_per_call\s+Float64/, query_events_sql)
    assert_match(/rows_returned_or_affected_state\s+AggregateFunction\(sum,\s+UInt64\)/, fingerprints_sql)
    assert_match(/shared_blks_hit_state\s+AggregateFunction\(sum,\s+UInt64\)/, fingerprints_sql)
    assert_match(/shared_blks_read_state\s+AggregateFunction\(sum,\s+UInt64\)/, fingerprints_sql)
    assert_match(/local_blks_hit_state\s+AggregateFunction\(sum,\s+UInt64\)/, fingerprints_sql)
    assert_match(/local_blks_read_state\s+AggregateFunction\(sum,\s+UInt64\)/, fingerprints_sql)
    assert_match(/temp_blks_read_state\s+AggregateFunction\(sum,\s+UInt64\)/, fingerprints_sql)
    assert_match(/temp_blks_written_state\s+AggregateFunction\(sum,\s+UInt64\)/, fingerprints_sql)
    assert_match(/total_block_accesses_state\s+AggregateFunction\(sum,\s+UInt64\)/, fingerprints_sql)
    assert_includes mv_sql, "sumState(rows_returned_or_affected) AS rows_returned_or_affected_state"
    assert_includes mv_sql, "sumState(shared_blks_hit) AS shared_blks_hit_state"
    assert_includes mv_sql, "sumState(shared_blks_read) AS shared_blks_read_state"
    assert_includes mv_sql, "sumState(local_blks_hit) AS local_blks_hit_state"
    assert_includes mv_sql, "sumState(local_blks_read) AS local_blks_read_state"
    assert_includes mv_sql, "sumState(temp_blks_read) AS temp_blks_read_state"
    assert_includes mv_sql, "sumState(temp_blks_written) AS temp_blks_written_state"
    assert_includes mv_sql, "sumState(total_block_accesses) AS total_block_accesses_state"
  end

  private

  def read_sql(name)
    File.read(File.expand_path("../../db/clickhouse/#{name}", __dir__))
  end
end
