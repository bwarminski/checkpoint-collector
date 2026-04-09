-- ABOUTME: Resets the fingerprint read model after schema changes.
-- ABOUTME: Run this only while collector ingestion is stopped so no raw events are missed.
DROP TABLE IF EXISTS top_offenders_mv;
DROP TABLE IF EXISTS query_fingerprints;

CREATE TABLE query_fingerprints (
  fingerprint String,
  representative_state AggregateFunction(argMax, Tuple(Nullable(String), Nullable(String)), DateTime64(3)),
  total_exec_count_state AggregateFunction(sum, UInt64),
  total_exec_time_ms_state AggregateFunction(sum, Float64),
  rows_returned_or_affected_state AggregateFunction(sum, UInt64),
  shared_blks_hit_state AggregateFunction(sum, UInt64),
  shared_blks_read_state AggregateFunction(sum, UInt64),
  local_blks_hit_state AggregateFunction(sum, UInt64),
  local_blks_read_state AggregateFunction(sum, UInt64),
  temp_blks_read_state AggregateFunction(sum, UInt64),
  temp_blks_written_state AggregateFunction(sum, UInt64),
  total_block_accesses_state AggregateFunction(sum, UInt64),
  p95_exec_time_state AggregateFunction(quantile(0.95), Float64)
) ENGINE = AggregatingMergeTree
ORDER BY (fingerprint);

INSERT INTO query_fingerprints
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
