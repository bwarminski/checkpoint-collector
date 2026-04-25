# Changelog

## [0.4.0.0] — 2026-04-25

**Mixed missing-index workload.** Expands the `missing-index-todos` workload from a single-action probe into a seven-action mixed shape, adds a fixture verifier, soak-mode invariant sampling, and a dominance assertion in the oracle so the bad plan stays attributable end-to-end.

### Added

- **Mixed workload actions.** `CreateTodo`, `CloseTodo`, `DeleteCompletedTodos`, `FetchCounts`, `ListRecentTodos`, `SearchTodos` join `ListOpenTodos`. Weights `[68,12,7,7,3,2,3]` keep `GET /api/todos?status=open` dominant on `pg_stat_statements`. Write actions sample `user_id`/`todo_id` per call from the worker RNG against `Workload.scale.rows_per_table`.
- **`Load::FixtureVerifier`.** Pre-flight check, gated to `missing-index-todos`, that asserts the bad plan's Seq Scan, the `/api/todos/counts` N+1 fan-out, and the search EXPLAIN tree shape against `fixtures/mixed-todo-app/search-explain.json`. Wired into `bin/load run` (finite + continuous) and `bin/load verify-fixture` as a standalone command.
- **Soak-mode invariant sampling.** `Load::Runner::InvariantSampler` polls `open_count` and `total_count` on a dedicated PG connection (`SET LOCAL pg_stat_statements.track = 'none'`) every 60s. Three consecutive breaches of the open/total floor/ceiling abort the run with `error_code: invariant_breach`; samples land in `run.json#invariant_samples`.
- **Dominance assertion.** Oracle now ranks ClickHouse `query_intervals` by `total_exec_count * avg_exec_time_ms` and requires the primary queryid to be ≥3× the next challenger.
- **`bin/load verify-fixture`.** Standalone CLI command that runs adapter `describe → prepare → reset_state → start → readiness → verify → stop`.

### Changed

- **Pre-flight gate ordering.** Runner now executes `probe_readiness → verify_fixture → start_workers`. Soak runs share the gate.
- **Reset-state queryid fingerprint.** Adapter's `reset_state` warms the bad plan with the full ORDER BY/LIMIT/OFFSET shape so `pg_stat_statements` resolves a stable queryid the oracle can reuse on lookup fallback.
- **Search EXPLAIN comparison.** Verifier matches against a stable subset of plan keys (`Node Type`, `Relation Name`, `Sort Key`, `Filter`, `Plans`) so volatile costs/widths don't flap.

### Fixed

- **Stop-reason coalescing.** `InternalStopFlag#trigger` preserves the first reason so a SIGTERM during a breach window doesn't mask `:invariant_breach`.



**Load runner MVP.** Replaces the fixture harness with a generic Ruby load runner, a narrow Rails bench adapter, and one concrete `missing-index-todos` workload that reproduces the Seq-Scan pathology through normal app traffic.

### Added

- **`bin/load`** — new CLI for running workloads against an app under test. `bin/load run --workload <name> --adapter <path> --app-root <path>` is the entrypoint.
- **`/load`** — the runner core: worker pool, rate limiter, readiness gate, HTTP client with persistent connections, metrics buffer and periodic reporter, run record (atomic `run.json` writes + `metrics.jsonl` + `adapter-commands.jsonl`), signal-based shutdown with bounded drain.
- **`/adapters/rails`** — Rails bench adapter binary implementing the `describe / prepare / migrate / load-dataset / reset-state / start / stop` contract over JSON stdio. Includes a Postgres template cache keyed by schema digest + seed-time environment, process-group lifecycle for the app-under-test, and `pg_stat_statements` reset on every run.
- **`/workloads/missing_index_todos`** — first workload. HTTP action that hits `GET /todos/status?status=open`; oracle tree-walks EXPLAIN JSON for a `Seq Scan` on `todos` and polls ClickHouse `query_intervals` for `pg_stat_statements` call counts.
- **`Load::WorkloadRegistry`** — explicit `Load::WorkloadRegistry.register("name", Klass)` replaces the earlier `--workload PATH` + `ObjectSpace` class discovery.

### Removed

- **`bin/fixture`** and the entire fixture harness (`collector/lib/fixtures/`, `collector/test/fixtures/`, `fixtures/missing-index/`, `load/harness.rb`, `load/test/harness_test.rb`, `fixture-harness-walkthrough.md`). The runner + adapter + workload contract is the replacement.

### Changed

- **Run artifacts** now include `schema_version: 1` for forward compatibility. `adapter-commands.jsonl` redacts URL credentials and `*_URL / *_PASSWORD / *_TOKEN / *_KEY / *_SECRET` env values before write.

### Fixed (pre-release ship review)

Findings from the 2026-04-23 ship review (`docs/superpowers/plans/2026-04-23-load-runner-ship-review.md`), all landed before the first tagged release:

- **Silent benchmark corruption.** `TemplateCache` previously keyed templates on schema digest alone; a clone-hit from a prior smaller-scale run would silently restore the wrong dataset. Key now includes a digest of seed-time env vars (`SEED`, `ROWS_PER_TABLE`, `OPEN_FRACTION`, plus any workload-specific env).
- **Rate limiter serialization.** `Load::RateLimiter` held its mutex across `sleep`, serializing all workers behind the one currently sleeping. The limiter now reserves a future slot under the lock and sleeps after releasing it. Regression test uses real `Kernel.sleep` so the fake-sleeper path cannot mask future regressions.
- **Per-request TCP connections.** `Load::Client` opened a new HTTP connection for every request. Client now holds a persistent connection for the duration of the run and closes it in `ensure`. Each worker gets its own `Load::Client` instance (and therefore its own `Net::HTTP` session), verified by `test_runner_builds_one_client_per_worker`.
- **Shared mutex on the per-request counter path.** Request totals moved off the runner's shared mutex into per-worker `TrackingBuffer` instances, aggregated at snapshot time.
- **Reporter final interval.** `Reporter` now writes actual elapsed time as `interval_ms` for the tail flush instead of the configured value.
- **Secrets in run artifacts.** `adapter-commands.jsonl` redacts URL passwords and sensitive env keys before write.
- **Spec↔impl drift.** Spec now matches the implemented contract for `migrate` (`db:schema:load`), `reset-state --workload` + `query_ids`, `schema_version`, template-name format, invalidation rule, and the removal of `--debug-log`.
- **Thread-safety of shutdown.** `Load::Client#finish` is safe when `start` raised before the HTTP session began (discovered during SIGTERM flake debugging).

### Review history

Five structured review rounds in the branch log:
- Round 1 `plan-eng-review` — DO_NOT_SHIP (11 findings, 3 critical gaps)
- Round 2 `plan-eng-review` — SHIP_WITH_FIXES (4 residuals)
- Round 3 `plan-eng-review` — SHIP_WITH_FIXES (1 narrow residual)
- `ship` Step 9 — DO_NOT_SHIP (3 new P0s, 1 P1, 6 P2s surfaced by the auto-review army)
- Round 4 `plan-eng-review` — SHIP_WITH_FIXES (1 new P0 on worker client wiring)
- Round 4b `plan-eng-review` — CLEAR (worker client fix verified, all regressions tested)

### Deferred

P3 items from the ship review remain deferred:
- `command_name:` kwarg unused in `CommandRunner`
- `rails_env` helper duplicated across five Commands classes
- Dead `started_ns` assignment in `Worker#run`
- Magic numbers in `Runner` / `ReadinessGate` / port range
- `Result.wrap` error-code derivation from exception class name
- `Reporter#snapshot` sorts latencies twice per percentile
- Oracle ClickHouse polling opens a fresh connection per tick
