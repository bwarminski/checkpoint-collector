-- ABOUTME: Resets the query analytics read model after schema changes.
-- ABOUTME: Run this only while collector ingestion is stopped so no raw events are missed.
DROP TABLE IF EXISTS top_offenders_mv;
DROP TABLE IF EXISTS query_fingerprints;

CREATE TABLE query_fingerprints (
  fingerprint String,
  representative_state AggregateFunction(argMax, Tuple(Nullable(String), Nullable(String)), DateTime64(3)),
  delta_exec_count_state AggregateFunction(sum, UInt64),
  delta_exec_time_ms_state AggregateFunction(sum, Float64),
  delta_rows_returned_or_affected_state AggregateFunction(sum, UInt64),
  delta_shared_blks_hit_state AggregateFunction(sum, UInt64),
  delta_shared_blks_read_state AggregateFunction(sum, UInt64),
  delta_local_blks_hit_state AggregateFunction(sum, UInt64),
  delta_local_blks_read_state AggregateFunction(sum, UInt64),
  delta_temp_blks_read_state AggregateFunction(sum, UInt64),
  delta_temp_blks_written_state AggregateFunction(sum, UInt64),
  delta_total_block_accesses_state AggregateFunction(sum, UInt64),
  p95_exec_time_state AggregateFunction(quantile(0.95), Float64)
) ENGINE = AggregatingMergeTree
ORDER BY (fingerprint);

INSERT INTO query_fingerprints
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
