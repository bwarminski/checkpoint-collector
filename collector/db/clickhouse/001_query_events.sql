-- ABOUTME: Creates the raw query events table for collector inserts.
-- ABOUTME: Stores per-query counters, timing, and metadata snapshots.
CREATE TABLE query_events (
  collected_at DateTime64(3),
  dbid UInt64,
  userid UInt64,
  toplevel Bool,
  queryid String,
  statement_text Nullable(String),
  source_file Nullable(String),
  total_exec_count UInt64,
  total_exec_time_ms Float64,
  rows_returned_or_affected UInt64,
  shared_blks_hit UInt64,
  shared_blks_read UInt64,
  local_blks_hit UInt64,
  local_blks_read UInt64,
  temp_blks_read UInt64,
  temp_blks_written UInt64,
  total_block_accesses UInt64,
  min_exec_time_ms Float64,
  max_exec_time_ms Float64,
  mean_exec_time_ms Float64,
  stddev_exec_time_ms Float64
) ENGINE = MergeTree
ORDER BY (dbid, userid, toplevel, queryid, collected_at);
