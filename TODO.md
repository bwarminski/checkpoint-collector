# TODO

- Split PostgreSQL log ingestion into a separate pipeline. The current collector only reads the active `POSTGRES_LOG_PATH` file and resets to byte `0` when that file shrinks, so it does not recover unread history from older rotated log files after downtime. This is acceptable for the demo, but not for durable ingestion.
