-- ABOUTME: Creates the log ingestion state table for Postgres JSON log imports.
-- ABOUTME: Stores the last processed file offsets so ingestion can resume after restarts.
CREATE TABLE IF NOT EXISTS postgres_log_state (
  log_file String,
  byte_offset UInt64,
  file_size_at_last_read UInt64,
  collected_at DateTime64(3)
) ENGINE = MergeTree
ORDER BY (log_file);
