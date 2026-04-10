-- ABOUTME: Rebuilds the raw query events, collector state, and interval view schema.
-- ABOUTME: Drops and recreates raw tables plus the query intervals view.
DROP VIEW IF EXISTS query_intervals;
DROP TABLE IF EXISTS collector_state;
DROP TABLE IF EXISTS query_events;

CREATE TABLE query_events (
  collected_at DateTime64(3),
  dbid UInt64,
  userid UInt64,
  toplevel Bool,
  queryid String,
  fingerprint String,
  source_file Nullable(String),
  sample_query Nullable(String),
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

CREATE TABLE collector_state (
  collected_at DateTime64(3),
  dealloc UInt64,
  stats_reset DateTime
) ENGINE = MergeTree
ORDER BY (collected_at);

SET allow_experimental_analyzer = 0;
CREATE VIEW query_intervals AS
WITH interval_candidates AS (
  SELECT
    e.collected_at,
    e.dbid,
    e.userid,
    e.toplevel,
    e.queryid,
    e.fingerprint,
    e.source_file,
    e.sample_query,
    e.total_exec_count,
    e.total_exec_time_ms,
    e.rows_returned_or_affected,
    e.shared_blks_hit,
    e.shared_blks_read,
    e.local_blks_hit,
    e.local_blks_read,
    e.temp_blks_read,
    e.temp_blks_written,
    e.total_block_accesses,
    e.min_exec_time_ms,
    e.max_exec_time_ms,
    e.mean_exec_time_ms,
    e.stddev_exec_time_ms,
    s.stats_reset,
    row_number() OVER statement_window AS snapshot_position,
    lagInFrame(e.collected_at) OVER statement_window AS previous_collected_at,
    lagInFrame(e.total_exec_count) OVER statement_window AS previous_total_exec_count,
    lagInFrame(e.total_exec_time_ms) OVER statement_window AS previous_total_exec_time_ms,
    lagInFrame(e.rows_returned_or_affected) OVER statement_window AS previous_rows_returned_or_affected,
    lagInFrame(e.shared_blks_hit) OVER statement_window AS previous_shared_blks_hit,
    lagInFrame(e.shared_blks_read) OVER statement_window AS previous_shared_blks_read,
    lagInFrame(e.local_blks_hit) OVER statement_window AS previous_local_blks_hit,
    lagInFrame(e.local_blks_read) OVER statement_window AS previous_local_blks_read,
    lagInFrame(e.temp_blks_read) OVER statement_window AS previous_temp_blks_read,
    lagInFrame(e.temp_blks_written) OVER statement_window AS previous_temp_blks_written,
    lagInFrame(e.total_block_accesses) OVER statement_window AS previous_total_block_accesses,
    lagInFrame(s.stats_reset) OVER statement_window AS previous_stats_reset
  FROM query_events AS e
  LEFT JOIN collector_state AS s USING (collected_at)
  WINDOW statement_window AS (PARTITION BY e.dbid, e.userid, e.toplevel, e.queryid ORDER BY e.collected_at)
),
valid_intervals AS (
  SELECT *
  FROM interval_candidates
  WHERE snapshot_position > 1
    AND stats_reset = previous_stats_reset
    AND total_exec_count >= previous_total_exec_count
    AND total_exec_time_ms >= previous_total_exec_time_ms
)
SELECT
  previous_collected_at AS interval_started_at,
  collected_at AS interval_ended_at,
  dateDiff('millisecond', previous_collected_at, collected_at) AS interval_duration_ms,
  dbid,
  userid,
  toplevel,
  queryid,
  fingerprint,
  source_file,
  sample_query,
  CAST(total_exec_count - previous_total_exec_count AS Int64) AS total_exec_count,
  CAST(total_exec_time_ms - previous_total_exec_time_ms AS Float64) AS delta_exec_time_ms,
  CAST(rows_returned_or_affected - previous_rows_returned_or_affected AS Int64) AS rows_returned_or_affected,
  CAST(shared_blks_hit - previous_shared_blks_hit AS Int64) AS shared_blks_hit,
  CAST(shared_blks_read - previous_shared_blks_read AS Int64) AS shared_blks_read,
  CAST(local_blks_hit - previous_local_blks_hit AS Int64) AS local_blks_hit,
  CAST(local_blks_read - previous_local_blks_read AS Int64) AS local_blks_read,
  CAST(temp_blks_read - previous_temp_blks_read AS Int64) AS temp_blks_read,
  CAST(temp_blks_written - previous_temp_blks_written AS Int64) AS temp_blks_written,
  CAST(total_block_accesses - previous_total_block_accesses AS Int64) AS total_block_accesses,
  min_exec_time_ms,
  max_exec_time_ms,
  mean_exec_time_ms,
  stddev_exec_time_ms
FROM valid_intervals;
