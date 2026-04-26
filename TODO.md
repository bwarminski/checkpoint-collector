# TODO

- Split PostgreSQL log ingestion into a separate pipeline. The current collector only reads the active `POSTGRES_LOG_PATH` file and resets to byte `0` when that file shrinks, so it does not recover unread history from older rotated log files after downtime. This is acceptable for the demo, but not for durable ingestion.
- Add optional PlanetScale branch-per-run support after remote reset/reseed works against an existing branch. The deferred design should cover branch creation, credential discovery, cleanup, billing safeguards, and whether to use `pscale` or the PlanetScale API directly.
