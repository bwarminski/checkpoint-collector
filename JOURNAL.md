# Journal

- Task 2 uses a root override in `Fixtures::Manifest.load` so tests can write temp fixture trees without touching repo fixtures.
- `Fixtures::Command` accepts `manifest_loader:` so command parsing can be tested without requiring real fixture implementations.
- `bin/fixture` is the top-level entrypoint and should stay thin; fixture behavior belongs under `collector/lib/fixtures/` and `fixtures/`.
- Task 2 command dispatch should treat handler failures as runtime errors, not usage errors.
- Invalid `--rate` input should be converted into an `OptionParser` parse error so the CLI prints usage instead of crashing.
- `bin/fixture missing-index reset` currently loads the full registry and therefore requires Task 4/5 files to exist before the CLI can run successfully.
- The fixture command registry now defers each fixture file `require` until that verb runs, so `reset` can work before `drive` and `assert` exist.
- The missing-index template must create `pg_stat_statements` itself; otherwise `fixture_01` clones successfully but `pg_stat_statements_reset()` fails at the end of reset.
- If template bootstrap fails after creating `fixture_01_tmpl`, reset must drop the template before re-raising so later runs do not reuse a poisoned database.
- Task 4 drive code uses a per-thread `RateLimiter` instance instead of sharing one limiter across worker threads.
- The live `bin/fixture missing-index drive --seconds 1 --concurrency 2 --rate unlimited` smoke run against a tiny local HTTP server wrote `tmp/fixture-last-run.json` with `request_count: 1194` and no stdout/stderr output.
- Task 4 fix: the drive path now shares one synchronized limiter across workers and rescues worker exceptions inside the run loop before re-raising in the main thread.
- Task 5 live `EXPLAIN` output on `fixture_01` has a `Gather` root with the `Seq Scan` on `todos` beneath it, so the assertion needs to walk the plan tree instead of assuming the scan is the top node.
- The real `bin/fixture missing-index assert --timeout-seconds 180` run in this environment completed the explain check and then timed out with `ClickHouse saw only 0 calls before timeout`.
