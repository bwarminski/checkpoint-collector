-- ABOUTME: Configures Postgres to emit structured statement-completion logs for local ingestion.
-- ABOUTME: Enables JSON logs with query IDs and stores them in the data directory log folder.
ALTER SYSTEM SET logging_collector = 'on';
ALTER SYSTEM SET log_destination = 'jsonlog';
ALTER SYSTEM SET log_directory = 'pg_log';
ALTER SYSTEM SET log_filename = 'postgresql.json';
ALTER SYSTEM SET log_min_duration_statement = '0';
