-- ABOUTME: Creates a delta-oriented view over raw query event snapshots.
-- ABOUTME: Derives reset-aware interval metrics for query fingerprint findings.
CREATE VIEW query_intervals AS
SELECT
  collected_at AS interval_ended_at,
  lagInFrame(collected_at) OVER interval_window AS interval_started_at,
  dateDiff('millisecond', lagInFrame(collected_at) OVER interval_window, collected_at) AS interval_duration_ms,
  collected_at,
  dbid,
  userid,
  toplevel,
  queryid,
  fingerprint,
  source_file,
  sample_query,
  total_exec_count,
  total_exec_time_ms,
  rows_returned_or_affected,
  shared_blks_hit,
  shared_blks_read,
  local_blks_hit,
  local_blks_read,
  temp_blks_read,
  temp_blks_written,
  total_block_accesses,
  min_exec_time_ms,
  max_exec_time_ms,
  mean_exec_time_ms,
  stddev_exec_time_ms,
  stats_reset,
  if(
    stats_reset != lagInFrame(stats_reset) OVER interval_window,
    total_exec_count,
    total_exec_count - lagInFrame(total_exec_count) OVER interval_window
  ) AS delta_exec_count,
  if(
    stats_reset != lagInFrame(stats_reset) OVER interval_window,
    total_exec_time_ms,
    total_exec_time_ms - lagInFrame(total_exec_time_ms) OVER interval_window
  ) AS delta_exec_time_ms,
  if(
    stats_reset != lagInFrame(stats_reset) OVER interval_window,
    rows_returned_or_affected,
    rows_returned_or_affected - lagInFrame(rows_returned_or_affected) OVER interval_window
  ) AS delta_rows_returned_or_affected,
  if(
    stats_reset != lagInFrame(stats_reset) OVER interval_window,
    shared_blks_hit,
    shared_blks_hit - lagInFrame(shared_blks_hit) OVER interval_window
  ) AS delta_shared_blks_hit,
  if(
    stats_reset != lagInFrame(stats_reset) OVER interval_window,
    shared_blks_read,
    shared_blks_read - lagInFrame(shared_blks_read) OVER interval_window
  ) AS delta_shared_blks_read,
  if(
    stats_reset != lagInFrame(stats_reset) OVER interval_window,
    local_blks_hit,
    local_blks_hit - lagInFrame(local_blks_hit) OVER interval_window
  ) AS delta_local_blks_hit,
  if(
    stats_reset != lagInFrame(stats_reset) OVER interval_window,
    local_blks_read,
    local_blks_read - lagInFrame(local_blks_read) OVER interval_window
  ) AS delta_local_blks_read,
  if(
    stats_reset != lagInFrame(stats_reset) OVER interval_window,
    temp_blks_read,
    temp_blks_read - lagInFrame(temp_blks_read) OVER interval_window
  ) AS delta_temp_blks_read,
  if(
    stats_reset != lagInFrame(stats_reset) OVER interval_window,
    temp_blks_written,
    temp_blks_written - lagInFrame(temp_blks_written) OVER interval_window
  ) AS delta_temp_blks_written,
  if(
    stats_reset != lagInFrame(stats_reset) OVER interval_window,
    total_block_accesses,
    total_block_accesses - lagInFrame(total_block_accesses) OVER interval_window
  ) AS delta_total_block_accesses
FROM query_events
LEFT JOIN collector_state USING (collected_at)
WINDOW interval_window AS (PARTITION BY dbid, userid, toplevel, queryid ORDER BY collected_at);
