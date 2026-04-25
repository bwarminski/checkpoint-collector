# Mixed Missing-Index Todo Fixture — Design Spec

**Status:** Spec, ready for review
**Date:** 2026-04-24
**Builds on:** `docs/superpowers/specs/2026-04-19-load-forge-mvp-design.md`

## 1. Overview

The current `missing-index-todos` fixture is too narrow for the agent exercise Brett wants to run. It reliably reproduces one pathology, but the traffic shape is unrealistically clean: one dominant endpoint, one dominant query family, and very little background noise.

This change keeps the fixture name and the primary oracle contract, but replaces the underlying app and workload behavior with a richer TodoMVC-shaped JSON API and a mixed traffic pattern. The new fixture still leaves the missing `todos.status` index as the primary pathology, but it also preserves other classic app/database problems that an autonomous agent may notice while diagnosing the system:

- missing index on `todos.status` for the dominant "list open todos" path
- count-side N+1 behavior
- one text-search/query-shape pathology corresponding to the earlier `oracle/rewrite-like` fix family

The result should feel like a small realistic app under mixed traffic, not a single-purpose benchmark endpoint.

## 2. Goals and Non-Goals

### Goals

1. Preserve the current fixture identity: the workload stays named `missing-index-todos`.
2. Keep the primary oracle focused on the missing-index pathology only.
3. Replace the single-action workload with a mixed-action workload that still makes the missing-index path dominant.
4. Support both finite benchmark runs and long-running background traffic for live diagnosis sessions.
5. Keep the app-under-test in `~/db-specialist-demo` and evolve it into a fixture-friendly TodoMVC-style JSON service rather than introducing a second demo app.
6. Preserve as much of the current pathology surface as is practical, including the count-side N+1 and the older text-search/query-shape issue.

### Non-Goals

1. Introduce a second formal oracle for the N+1 or text-search issues in this round.
2. Rebrand the workload or rename the fixture. The existing `missing-index-todos` name stays in place for continuity.
3. Rewrite merged history to make the app evolution look more organic.
4. Turn the benchmark app into a full frontend TodoMVC implementation. The fixture app is JSON API only.

## 3. Why This Exists

The agent exercise Brett wants to run starts with `checkpoint-collector`, a live Postgres, and a live app, but without direct access to the demo app repo. That means the exercise only works if the observable system has both:

- a dominant diagnosable signal that points to the real problem
- enough legitimate background traffic that diagnosis requires judgment rather than one obvious bad endpoint

The current fixture only satisfies the first condition. This design adds the second without losing the first.

## 4. System Shape

The fixture continues to span two repos:

- `~/checkpoint-collector`
  - owns the workload definition, runner/oracle behavior, docs, and verification flow
- `~/db-specialist-demo`
  - remains the app-under-test and gains the richer Todo JSON API surface

The benchmark still runs against normal app HTTP routes and normal database tables. The collector still observes the system through `pg_stat_statements` and ClickHouse. No benchmark-only observability path is added.

## 5. App-Under-Test Design

`~/db-specialist-demo` becomes a small TodoMVC-shaped JSON API over the existing `users` and `todos` tables.

### 5.1 Data model

The schema remains intentionally simple:

- `users`
- `todos`
  - `user_id`
  - `status`
  - title/content fields as needed by the existing app shape

The broken schema characteristic remains explicit:

- index on `todos.user_id`
- **no index on `todos.status`**

This omission is intentional and remains the primary oracle target.

### 5.2 JSON routes

The app exposes these routes:

- `GET /api/todos`
  - query params:
    - `status=open|closed|all`
    - `page`
    - `per_page`
    - `order=created_desc`
  - default ordering is newest-first
  - `status=open` is the canonical missing-index read path

- `POST /api/todos`
  - creates one todo for a chosen user

- `PATCH /api/todos/:id`
  - updates a todo, primarily used to mark open todos closed

- `DELETE /api/todos/completed`
  - bulk-deletes completed/non-open todos
  - bounded per call; see §5.2.1

- `GET /api/todos/counts`
  - returns counts in a way that preserves the count-side N+1 pathology

- `GET /api/todos/search`
  - preserves the old text-search/query-shape pathology associated with the earlier `rewrite_like` fix family

### 5.2.1 Bulk delete must be bounded

The `DELETE /api/todos/completed` endpoint must be bounded per call. Acceptable shapes:

- **per-user scope:** `DELETE FROM todos WHERE user_id = $1 AND status != 'open'` — deletes one user's completed rows; mean batch size ≈ `total_completed / users` and auto-stabilizes (more closed rows produce larger batches).
- **explicit LIMIT:** delete a fixed N (e.g., 50) of the oldest completed rows per call.

Unbounded `DELETE FROM todos WHERE status != 'open'` is forbidden. A single such call collapses the closed pool and breaks the §6.2 `total_count` invariant for the remainder of the run. The constraint is load-bearing: a future "cleanup" PR that reaches for `Todo.where.not(status: 'open').destroy_all` silently destroys the soak-mode contract.

### 5.3 Pathology preservation

The new API should preserve three issue classes; each has an explicit protection contract:

1. **Missing index** (primary, oracle-backed)
   - dominant path: `GET /api/todos?status=open`
   - expected failure mode: seq scan on `todos`
   - protection: §8 oracle (run-time assertion + dominance margin)

2. **Count-side N+1** (secondary, smoke-backed)
   - exposed via `GET /api/todos/counts`
   - expected failure mode: more than one distinct queryid attributable to a single `/counts` call
   - protection: §8.2 verify-fixture pre-flight smoke

3. **Text-search/query-shape issue** (secondary, smoke-backed)
   - exposed via `GET /api/todos/search`
   - expected failure mode: EXPLAIN tree contains the rewrite_like-family filter shape (intentionally fixable by rewriting app code, not by adding the missing status index)
   - protection: §8.2 verify-fixture pre-flight smoke
   - reference: pattern derived from the existing `oracle/rewrite-like` history and stored in the smoke fixture; not reimagined from operator memory.

### 5.4 Dataset size

The benchmark dataset is sized to keep the seq-scan on `todos.status = 'open'` above ~5ms `mean_exec_time` when warm. Initial target: `ROWS_PER_TABLE = 100000`, `OPEN_FRACTION = 0.6`.

Smaller dataset sizes (e.g., for CI) MUST re-verify the §8 dominance margin at the new scale — the workload is not portable across dataset sizes without re-checking. Smaller seeded datasets also shrink the §6.2 `open_floor` and `total_floor` proportionally.

## 6. Workload Design

The workload remains named `missing-index-todos`, but the action mix becomes mixed rather than single-purpose.

### 6.1 Default action mix

Verified default weights:

- `68` list open todos
- `12` list recent pages of all todos
- `7` create todo
- `7` close todo
- `3` delete completed
- `2` fetch counts
- `3` text search

These are relative weights, not percentages. The operative contract is the resulting traffic shape and the §8 dominance margin, not a requirement that the weights sum to 100.

The key requirement is not the exact percentages. It is that:

- the open-todos path remains dominant in `pg_stat_statements` (see definition below)
- the other actions create legitimate query noise
- the mutation rate does not erase the open-todo distribution too quickly during a long run

**"Dominant" is defined in `pg_stat_statements` terms.** The list-open queryid must hold the largest `total_exec_time` over the run window, by at least 3× the next queryid. Counting by `calls` is not sufficient — a cheap, frequent query can lose to a rare, expensive one when the agent sorts by database time.

The action weights above target this margin at the §5.4 dataset size; they are back-checked against per-action cost estimates and re-verified by the §8 oracle on every run. If the §5.4 dataset size changes, the back-check must be re-run.

### 6.2 Shared mutable dataset

All actions operate on the same shared dataset. Writes are real and persistent for the duration of the run. This is intentional: the system should look like a live app under background use, not like a frozen benchmark image.

**Steady-state invariants.** Soak mode requires two stationary properties:

- `open_count ≥ open_floor` (default: `0.3 × ROWS_PER_TABLE`) — keeps the seq-scan returning a bulk result so its `mean_exec_time` stays high.
- `total_count ∈ [total_floor, total_ceiling]` (default: `[0.8, 2.0] × ROWS_PER_TABLE`) — keeps the *scan cost* stable; a monotonically growing table makes `mean_exec_time` drift over the run, which confuses an agent looking at trends.

Floors are tied to §5.4: smaller seeded datasets shrink the floors proportionally, but the §8 dominance margin must be re-checked at the new scale.

Action weights must satisfy:

- `E[Δopen]/req ≥ 0`
- `E[Δtotal]/req ≈ 0` (within `±ε`; `ε` set so a 24h soak drifts < 20% of seed size)

With the §6.1 weights and the §5.2.1 delete bound, expected per-request effects are:

- `Δopen  = +0.07 (create) − 0.07 (close)            = 0`
- `Δtotal = +0.07 (create) − 0.03 × batch (delete)`
- `       ≈ 0` when `batch_size ≈ 2.3`

The per-user delete shape (§5.2.1) auto-produces `batch_size ≈ total_completed / users`, which self-stabilizes. The fixed-LIMIT shape requires `LIMIT ≈ 2-3` to satisfy the invariant.

## 7. Execution Modes

The workload supports two modes:

### 7.1 Finite mode

This is the current benchmark/smoke/parity mode:

- fixed duration
- reproducible enough for local verification
- still used by the primary oracle

### 7.2 Continuous mode

This is a new long-running mode for agent diagnosis sessions:

- runs until interrupted
- keeps traffic flowing in the background
- uses the same workload/action mix as finite mode
- should shut down cleanly on signal

The runner interface should model this as a distinct execution mode rather than an overloaded infinite-duration sentinel. The expected top-level shape is:

- `bin/load run ...` for finite runs
- `bin/load soak ...` for continuous runs

The exact CLI spelling can change during implementation if needed, but the distinction between finite and continuous execution should stay explicit.

**Runtime invariant sampling.** Soak mode samples `open_count` and `total_count` every 60s. `open_count` is a real `SELECT COUNT(*) FROM todos WHERE status='open'`; `total_count` reads `pg_class.reltuples::bigint` for cheap approximate cardinality.

The sampler runs on a **dedicated PG connection** with `SET LOCAL pg_stat_statements.track = 'none'` so the sampler's own queries do not land in `pg_stat_statements` and pollute the §8 dominance attribution.

Each breach sample (any value outside the §6.2 `open_floor` / `total_floor` / `total_ceiling`) emits a warning to the run record. **Three consecutive breach samples** abort the run cleanly with non-zero exit (≈3 minutes at the 60s sampling cadence). A healthy sample resets the consecutive-breach counter to zero — a single bad sample followed by recovery does not abort.

The premise: the workload has drifted out of the regime the §8 dominance back-check was tuned for, so the agent exercise is no longer valid even if the run is still emitting traffic. Better to abort loudly than soak indefinitely on a degraded fixture.

## 8. Oracle Scope

The oracle remains intentionally narrow in this round on the *primary* pathology, but adds a dominance-margin assertion and a pre-flight smoke for the secondary pathologies.

It should continue to assert:

- the missing-index explain signal
- the corresponding ClickHouse/query-id signal for that dominant query family
- **dominance margin:** the missing-index queryid's `total_exec_time` over the run window is ≥3× the next queryid's. This catches silent traffic-shape regressions (a heavier endpoint added, dataset shrunk, counts pathology accidentally fixed) that would invalidate the agent exercise without flipping the EXPLAIN signal.

It should **not** fail the run merely because:

- the N+1 counts path exists
- the text-search issue exists
- mixed traffic introduces additional noisy query families

Those secondary issues are part of the diagnosis environment, not part of the formal pass/fail gate yet — but they ARE protected by the §8.2 pre-flight smoke against silent rot.

### 8.1 Where the oracle reads from

Dominance is asserted via ClickHouse `query_intervals` (aggregated from `pg_stat_statements` snapshots), not `pg_stat_statements` directly. This tests the full collector pipeline as a side effect of the oracle and avoids re-implementing aggregation in the runner.

### 8.2 Pre-flight verification (verify-fixture smoke)

A standalone `bin/load verify-fixture` command asserts all three §5.3 pathologies exist on a freshly seeded `db-specialist-demo`. It runs as the **first step of every finite and soak run** (pre-flight gate) and is also runnable manually or from CI.

Assertions, each independent and short-circuit on failure:

1. **Missing-index:** `GET /api/todos?status=open` EXPLAIN tree contains `Seq Scan on todos` with a `status` filter. Reuses the §8 oracle tree-walk.
2. **Counts N+1:** reset `pg_stat_statements`; issue one `GET /api/todos/counts`; derive `users_count` from the response body; snapshot. The summed `calls` attributable to the per-user `COUNT(*)` query family must be at least `users_count`. This catches both "someone removed the N+1 entirely" and the subtler consolidation-to-`GROUP BY` case that still leaves multiple queryids but no longer issues one count query per user.
3. **Search rewrite:** `GET /api/todos/search?q=foo` EXPLAIN tree contains a Seq Scan with a Filter matching the rewrite_like reference pattern stored at `fixtures/mixed-todo-app/search-explain.json`.

A failed assertion aborts the run before traffic starts, with a message naming the rotten pathology and the file/route most likely responsible.

The smoke is also wired into `db-specialist-demo` CI as a required check (see §11), so PRs that erode a pathology fail there before reaching the benchmark.

Pre-flight is preferred over run-time warnings because (a) run-time warnings get ignored once they appear in every run record, and (b) attribution is cleanest with a freshly-reset `pg_stat_statements` and a single isolated request.

## 9. Agent-Exercise Success Criteria

The richer fixture is successful if an agent starting from `checkpoint-collector` plus live services can:

1. Observe a dominant bad query family in `pg_stat_statements` and ClickHouse.
2. Distinguish that query family from background workload noise.
3. Form a reasonable hypothesis that the main issue is a missing index on `todos.status`.
4. Notice that there are additional non-primary issues in the system, including counts and search behavior.
5. Make progress on diagnosis before seeing the demo-app source.

The fixture is **not** required to make every issue equally obvious. The design intentionally biases visibility toward the missing-index path.

## 10. Verification Shape

Verification splits into two levels:

### 10.1 Finite verification

- benchmark run remains oracle-backed
- broken app should still pass the missing-index oracle
- the future index-fix branch should still flip the explain assertion as it does today

### 10.2 Continuous verification

- basic correctness only:
  - starts
  - emits mixed traffic
  - handles shutdown cleanly
- no attempt to define a full deterministic parity contract for indefinite runs

## 11. Cross-Repo Impact

### `checkpoint-collector`

- replace the current single-action `missing-index-todos` workload with the richer mixed workload
- add continuous execution support
- keep the oracle narrow
- update README and operator guidance for finite vs continuous usage

### `db-specialist-demo`

- add the Todo JSON API routes
- preserve the missing `status` index
- preserve the counts and search pathologies
- keep the benchmark seeding path compatible with the existing adapter contract
- wire `bin/load verify-fixture` (§8.2) into demo-app CI as a required check; PRs touching `/api/todos`, `/api/todos/counts`, or `/api/todos/search` MUST pass it before merge

## 12. Deliberate Decisions

- Keep the fixture name `missing-index-todos` for continuity.
- Keep the oracle narrow for now.
- Use the existing demo app, not a new app.
- Add JSON API routes, not server-rendered HTML pages.
- Support both finite and continuous runs.
- Preserve multiple pathologies, but keep one primary pathology dominant.
- Do not rewrite merged history to make the fixture evolution look older than it is.

## 13. Risks

1. **Background writes can self-erode the primary pathology**
   - mitigated by action weights and seeded distribution tuning

2. **Too much noise can make the exercise incoherent**
   - mitigated by keeping the open-todos path clearly dominant

3. **The search pathology may drift from the intended historical issue**
   - mitigated by deriving it from the old `rewrite_like` fix lineage rather than inventing a fresh bad query

4. **Continuous mode can grow operationally messy**
   - mitigated by keeping it as the same workload shape with a different lifetime, not a separate runner subsystem

5. **Dataset-scale fragility**
   - small CI datasets can collapse the §8 dominance margin (cheap seq-scan on a small table loses to a more expensive search query)
   - mitigated by §5.4 dataset pin + §8 dominance assertion (which fails loudly if the margin breaks)

6. **Bulk-delete semantics**
   - unbounded `DELETE WHERE status != 'open'` collapses the closed pool in one call and breaks the §6.2 `total_count` invariant
   - mitigated by §5.2.1 forbidding the unbounded shape

7. **Floor breach during soak**
   - dataset can drift outside the §6.2 steady-state envelope under sustained traffic-shape skew (e.g., user-distribution imbalance)
   - mitigated by §7.2 invariant sampling + abort

## 14. Out of Scope Follow-Ups

- Promoting counts-N+1 or search-rewrite from smoke-only to full oracle (assert exact subquery counts, assert ClickHouse `query_intervals` signal, fail benchmark runs on margin breach). The §8.2 smoke protects existence; promotion to a margin-based oracle is deferred until the agent exercise proves the signal is needed for diagnosis.
- Adding a second benchmark app
- Converting the fixture into a full browser-facing TodoMVC frontend
- Generalizing the mixed workload into a broad scenario library
