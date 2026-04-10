-- ABOUTME: Creates the collector state table for stats reset metadata.
-- ABOUTME: Stores per-poll pg_stat_statements_info snapshots.
CREATE TABLE collector_state (
  collected_at DateTime64(3),
  dealloc UInt64,
  stats_reset DateTime
) ENGINE = MergeTree
ORDER BY (collected_at);
