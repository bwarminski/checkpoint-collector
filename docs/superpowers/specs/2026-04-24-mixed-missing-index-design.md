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

- `GET /api/todos/counts`
  - returns counts in a way that preserves the count-side N+1 pathology

- `GET /api/todos/search`
  - preserves the old text-search/query-shape pathology associated with the earlier `rewrite_like` fix family

### 5.3 Pathology preservation

The new API should preserve three issue classes:

1. **Missing index**
   - dominant path: `GET /api/todos?status=open`
   - expected failure mode: seq scan on `todos`

2. **Count-side N+1**
   - exposed via `GET /api/todos/counts`
   - expected failure mode: repeated per-user or per-scope count queries instead of one set-based query

3. **Text-search/query-shape issue**
   - exposed via `GET /api/todos/search`
   - expected failure mode: intentionally poor query shape that is more naturally fixed by rewriting app code than by adding the missing status index

The exact implementation of the search pathology must be derived from the existing `oracle/rewrite-like` history, not reimagined from scratch.

## 6. Workload Design

The workload remains named `missing-index-todos`, but the action mix becomes mixed rather than single-purpose.

### 6.1 Default action mix

Recommended initial weights:

- 60-70% list open todos
- 10-15% list recent pages of all todos
- 5-10% create todo
- 5-10% close todo
- 2-5% delete completed
- 5-10% fetch counts
- 2-5% text search

The key requirement is not the exact percentages. It is that:

- the open-todos path remains the highest-volume query family
- the other actions create legitimate query noise
- the mutation rate does not erase the open-todo distribution too quickly during a long run

### 6.2 Shared mutable dataset

All actions operate on the same shared dataset. Writes are real and persistent for the duration of the run. This is intentional: the system should look like a live app under background use, not like a frozen benchmark image.

The workload must therefore balance writes against the seeded distribution so that long-running traffic stays useful. In practice:

- inserts must replenish open rows often enough
- close/delete behavior must not collapse the open set too quickly

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

## 8. Oracle Scope

The oracle remains intentionally narrow in this round.

It should continue to assert only:

- the missing-index explain signal
- the corresponding ClickHouse/query-id signal for that dominant query family

It should **not** fail the run merely because:

- the N+1 counts path exists
- the text-search issue exists
- mixed traffic introduces additional noisy query families

Those secondary issues are part of the diagnosis environment, not part of the formal pass/fail gate yet.

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

## 14. Out of Scope Follow-Ups

- Expanding the oracle to assert N+1 or search issues
- Adding a second benchmark app
- Converting the fixture into a full browser-facing TodoMVC frontend
- Generalizing the mixed workload into a broad scenario library
