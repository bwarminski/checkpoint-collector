-- ABOUTME: Creates the raw query events table for collector inserts.
-- ABOUTME: Stores per-query timing and source metadata for later fingerprinting.
CREATE TABLE query_events (
  collected_at DateTime64(3),
  fingerprint String,
  source_file Nullable(String),
  sample_query Nullable(String),
  total_exec_count UInt64,
  mean_exec_time_ms Float64,
  rows_returned_or_affected UInt64,
  shared_blks_hit UInt64,
  shared_blks_read UInt64,
  local_blks_hit UInt64,
  local_blks_read UInt64,
  temp_blks_read UInt64,
  temp_blks_written UInt64,
  total_block_accesses UInt64,
  mean_block_accesses_per_call Float64
) ENGINE = MergeTree
ORDER BY (fingerprint, collected_at);
