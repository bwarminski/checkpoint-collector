-- ABOUTME: Creates the raw Postgres JSON log table for collector ingestion.
-- ABOUTME: Stores statement text, source metadata, and raw payloads by file offset.
CREATE TABLE IF NOT EXISTS postgres_logs (
  log_file String,
  byte_offset UInt64,
  log_timestamp DateTime64(3),
  query_id String,
  statement_text Nullable(String),
  database Nullable(String),
  session_id Nullable(String),
  source_location Nullable(String),
  raw_json String
) ENGINE = ReplacingMergeTree
ORDER BY (log_file, byte_offset);
