# Changelog

## [0.5.0.0] — 2026-04-26

**PlanetScale reset/soak.** Adds an explicit remote reset strategy for the Rails adapter and a stats-only mode for the collector so `bin/load soak` can target an existing PlanetScale Postgres branch. Local Docker behavior is unchanged.

### Added

- **`BENCH_ADAPTER_RESET_STRATEGY=local|remote` reset strategy.** `local` (default) keeps template-clone behavior. `remote` skips the template cache, runs `db:schema:load` + `db/seeds.rb` against the existing database, ensures `pg_stat_statements`, captures workload query IDs, and resets stats. Schema-load and seed failures surface their stderr in the JSON error contract.
- **`COLLECTOR_DISABLE_LOG_INGESTION` collector flag.** When set, the collector skips `POSTGRES_LOG_PATH` reads and `postgres_logs` writes while still polling `pg_stat_statements` and writing `query_events`. The `log_ingestion_enabled` runtime kwarg is the in-process equivalent.
- **`make load-soak-planetscale` operator target.** Validates `DATABASE_URL` and `BENCH_ADAPTER_PG_ADMIN_URL`, runs `bin/load soak --workload missing-index-todos --invariants warn --startup-grace-seconds 60` with `BENCH_ADAPTER_RESET_STRATEGY=remote`. Slower Rails boot on PlanetScale and planner-stat estimate drift drove the grace and policy choices; both are documented in the README.
- **PlanetScale Soak README section.** Covers `pg_stat_statements` dashboard activation, `verify-full` + explicit CA bundle, direct vs pooled connection guidance, the reset/reseed checkpoint, and stats-only collector usage.

### Changed

- **Invariant sampler tracking opt-out is best-effort.** `Load::Workloads::MissingIndexTodos::InvariantSampler` issues `SET pg_stat_statements.track = 'none'` on its dedicated connection and tolerates `PG::InsufficientPrivilege` so PlanetScale-style restricted roles do not fail soak runs.
- **Verifier HTTP timeout.** `Load::Workloads::MissingIndexTodos::Verifier` uses a 30s `Load::Client` timeout for pre-flight checks; PlanetScale `/api/todos/counts` regularly exceeds the 5s default during cold start.
- **`Load::Client` accepts `timeout_seconds:`.** Clients can now override the default 5s read/open/write timeout per use case.

### Fixed

- **`close_todo` response parsing.** The action now reads `items` from the `{"items":[...]}` envelope returned by `/api/todos`; previously it parsed the body as a bare array and crashed under live soak traffic.
- **`make` PHONY contract.** New PlanetScale targets are listed under `.PHONY` so they remain phony alongside the existing operator shortcuts.

### Deferred

- Branch-per-run automation (covered by `pscale` or PlanetScale API).
- PlanetScale Cluster Logs / Query Insights / `pginsights` as a remote query-log evidence source.

## [0.4.0.0] — 2026-04-26

**Tenant-shaped mixed missing-index workload.** Expands `missing-index-todos` from a single-action probe into a tenant-scoped seven-action mixed shape, moves fixture verification ownership into the workload, adds soak-mode invariant sampling, and a dominance assertion in the oracle so the bad plan stays attributable end-to-end.

### Added

- **Mixed workload actions, tenant-shaped.** `CreateTodo`, `CloseTodo`, `DeleteCompletedTodos`, `FetchCounts`, `ListRecentTodos`, `SearchTodos` join `ListOpenTodos`. Weights `[68,12,7,7,3,2,3]` keep tenant-scoped `GET /api/todos?status=open` dominant on `pg_stat_statements`. All actions sample `user_id` per call from `Workload.scale.extra["USER_COUNT"]`; `CloseTodo` fetches one tenant's open todos and closes one of the returned candidates (no-op success when the tenant has none).
- **`USER_COUNT` scale knob.** Workload-specific extra that decouples tenant population from todo volume. Adapter seeds exactly `USER_COUNT` users and distributes todos across them while preserving `OPEN_FRACTION`.
- **Workload-owned fixture verifier.** Pre-flight check that asserts the tenant-scoped EXPLAIN shape (BitmapHeap/Index access via `index_todos_on_user_id`, residual `status` filter, sort by `created_at DESC, id DESC`), the `/api/todos/counts` N+1 fan-out, and the search EXPLAIN tree shape against `fixtures/mixed-todo-app/search-explain.json`. Wired into `bin/load run` (finite + continuous) and `bin/load verify-fixture`.
- **`Workload#verifier` and `Workload#invariant_sampler` hooks.** Workloads now own their domain-specific verifier and sampler construction. The core load library no longer carries todo-specific knowledge.
- **Soak-mode invariant sampling.** Polls `open_count` and `total_count` on a dedicated PG connection, attempts to disable `pg_stat_statements` tracking for the sampler connection, and tolerates databases that disallow that setting. Three consecutive breaches of the open/total floor/ceiling abort the run with `error_code: invariant_breach`; samples land in `run.json#invariant_samples`.
- **Dominance assertion.** Oracle ranks ClickHouse `query_intervals` by `total_exec_count * avg_exec_time_ms` and requires the primary queryid to be ≥3× the next challenger.
- **`bin/load verify-fixture`.** Standalone CLI command that runs adapter `describe → prepare → reset_state → start → readiness → verify → stop`.

### Changed

- **`run.json` schema_version 1 → 2.** `invariant_samples` entries no longer store fixture-specific top-level fields like `open_count`, `total_count`, `open_floor`, `total_floor`, and `total_ceiling`. They now store a workload-agnostic `checks` array of `{name, actual, min, max, breach, breaches}` records. Downstream tooling reading `run.json` should bump its expected schema version.
- **Pathology contract is tenant-scoped.** The bad query is no longer "no useful index at all" — it's "the app uses `index_todos_on_user_id` to find one tenant slice, then must still filter `status` and sort inside that slice." Verifier and oracle reflect this access pattern.
- **Pre-flight gate ordering.** Runner executes `probe_readiness → verify_fixture → start_workers`. Soak runs share the gate.
- **Reset-state queryid fingerprint.** Adapter warms the tenant-scoped query shape so `pg_stat_statements` resolves a stable queryid the oracle reuses on lookup fallback.
- **Runner internals decomposed.** `Load::Runner` becomes a coordinator over `RunState`, `LoadExecution`, and `InvariantMonitor`. `RunState` owns `run.json` schema and persistence; `LoadExecution` owns the worker/reporter/drain window; `InvariantMonitor` owns sampling thread and breach policy with nested `Config`/`Sink`/`State` helpers. Public CLI and workload contracts unchanged.
- **`Scale#extra` for workload-specific knobs.** Generic `Load::Scale` no longer carries todo-specific fields. Workload env propagates through `Scale.extra`, validated against a reserved-key list and uppercased on the way to the adapter.
- **Search EXPLAIN comparison.** Verifier matches against a stable subset of plan keys (`Node Type`, `Relation Name`, `Sort Key`, `Filter`, `Plans`) so volatile costs/widths don't flap.

### Fixed

- **Stop-reason coalescing.** `InternalStopFlag#trigger` preserves the first reason so a SIGTERM during a breach window doesn't mask `:invariant_breach`.
- **Tenant-scoped queryid capture.** Adapter's warm query previously fingerprinted a non-tenant query shape that didn't match production traffic; the warm now matches the real workload, so the oracle attributes correctly on lookup fallback.



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
