-- ABOUTME: Creates the aggregated query fingerprint findings table.
-- ABOUTME: Stores aggregate states consumed by the interval materialized view.
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
