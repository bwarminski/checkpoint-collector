-- ABOUTME: Builds the materialized view that aggregates query intervals.
-- ABOUTME: Feeds the query_fingerprints table from reset-aware deltas.
CREATE MATERIALIZED VIEW top_offenders_mv
TO query_fingerprints AS
SELECT
  fingerprint,
  argMaxState((source_file, sample_query), interval_ended_at) AS representative_state,
  sumState(delta_exec_count) AS delta_exec_count_state,
  sumState(delta_exec_time_ms) AS delta_exec_time_ms_state,
  sumState(delta_rows_returned_or_affected) AS delta_rows_returned_or_affected_state,
  sumState(delta_shared_blks_hit) AS delta_shared_blks_hit_state,
  sumState(delta_shared_blks_read) AS delta_shared_blks_read_state,
  sumState(delta_local_blks_hit) AS delta_local_blks_hit_state,
  sumState(delta_local_blks_read) AS delta_local_blks_read_state,
  sumState(delta_temp_blks_read) AS delta_temp_blks_read_state,
  sumState(delta_temp_blks_written) AS delta_temp_blks_written_state,
  sumState(delta_total_block_accesses) AS delta_total_block_accesses_state,
  quantileState(0.95)(delta_exec_time_ms) AS p95_exec_time_state
FROM query_intervals
GROUP BY fingerprint;
