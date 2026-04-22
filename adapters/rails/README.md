# ABOUTME: Documents the Rails benchmark adapter contract and runtime assumptions.
# ABOUTME: Explains how schema setup, seeding, and server lifecycle work for load runs.

# Rails Adapter

`adapters/rails/bin/bench-adapter` implements the MVP adapter contract for Rails apps.

## Contract Notes

- `describe` reports adapter metadata and supported commands.
- `prepare` checks bundle dependencies and verifies benchmark database reachability.
- `migrate` means "bring the benchmark database to the app's canonical schema". The current implementation uses `bin/rails db:create db:schema:load`.
- `load-dataset` runs `bin/rails runner 'load Rails.root.join("db/seeds.rb").to_s'` with `SEED` and each propagated scale env var.
- `reset-state` does a full reset: `db:drop`, `db:create`, `db:schema:load`, explicit seed, `CREATE EXTENSION IF NOT EXISTS pg_stat_statements`, then `pg_stat_statements_reset()`.
- `start` spawns `bin/rails server` on a free localhost port and returns immediately.
- `stop` sends `SIGTERM`, polls `kill(0, pid)`, then escalates to `SIGKILL` if needed. It never calls `waitpid`.

## Environment

Rails subprocesses run with:

- `RAILS_ENV=benchmark`
- `RAILS_LOG_LEVEL=warn`
- `SECRET_KEY_BASE_DUMMY=1`
- `BUNDLE_GEMFILE=<app_root>/Gemfile`

The adapter clears outer `bundle exec` state before spawning subprocesses and preserves local bundle path settings so fixture apps can install gems into `vendor/bundle`.

## Postgres Template Cache

Template cloning is adapter-private. The adapter connects to Postgres through `BENCH_ADAPTER_PG_ADMIN_URL` and falls back to `DATABASE_URL` when needed. It uses that admin connection to create and clone `<database>_tmpl` for fast reset cycles.
