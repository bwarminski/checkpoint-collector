-- ABOUTME: Builds the materialized view that aggregates raw query events.
-- ABOUTME: Feeds the query_fingerprints table from aggregated query events.
CREATE MATERIALIZED VIEW top_offenders_mv
TO query_fingerprints AS
SELECT
  fingerprint,
  argMaxState((source_file, sample_query), collected_at) AS representative_state,
  sumState(total_exec_count) AS total_exec_count_state,
  sumState(total_exec_count * mean_exec_time_ms) AS total_exec_time_ms_state,
  sumState(rows_returned_or_affected) AS rows_returned_or_affected_state,
  sumState(shared_blks_hit) AS shared_blks_hit_state,
  sumState(shared_blks_read) AS shared_blks_read_state,
  sumState(local_blks_hit) AS local_blks_hit_state,
  sumState(local_blks_read) AS local_blks_read_state,
  sumState(temp_blks_read) AS temp_blks_read_state,
  sumState(temp_blks_written) AS temp_blks_written_state,
  sumState(total_block_accesses) AS total_block_accesses_state,
  quantileState(0.95)(mean_exec_time_ms) AS p95_exec_time_state
FROM query_events
GROUP BY fingerprint;
