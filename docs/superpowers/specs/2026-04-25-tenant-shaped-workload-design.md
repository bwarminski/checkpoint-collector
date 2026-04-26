# Tenant-Shaped Missing-Index Workload Design

**Status:** Spec, ready for review
**Date:** 2026-04-25
**Builds on:** `docs/superpowers/specs/2026-04-24-mixed-missing-index-design.md`

## 1. Summary

The current `missing-index-todos` workload is still shaped like a single-tenant toy, even after the mixed-traffic expansion. Too many action semantics derive from `rows_per_table` as if it were both todo volume and user population. That makes the traffic less believable than it should be:

- user ids are sampled from todo volume
- `close_todo` targets arbitrary global todo ids
- list/search endpoints are effectively app-wide rather than tenant-scoped

At the same time, `Load::FixtureVerifier` still carries too much `missing-index-todos` knowledge in the core load library.

This change fixes both issues together:

1. reshape `missing-index-todos` into an explicitly tenant-shaped workload with user-scoped action semantics
2. move fixture verification ownership entirely into the workload instead of keeping todo-specific checks in `load/lib/load`

The workload becomes more realistic and the core load library becomes less todo-specific, but the primary pathology contract changes shape: once the app is tenant-scoped, the bad query is no longer “no useful index at all.” It becomes “the app can only use `todos.user_id`, then must still filter `status` and sort inside that tenant slice.”

## 2. Goals and Non-Goals

### Goals

1. Replace the implicit `users ~= rows_per_table` assumption with an explicit tenant count.
2. Keep tenant shape in `Load::Scale#extra`, not in the generic core scale type.
3. Make `list_open_todos`, `list_recent_todos`, and `search_todos` user-scoped.
4. Make `close_todo` operate on one user’s open todos, not a random global id guess.
5. Keep `delete_completed_todos` direct and user-scoped without an extra fetch.
6. Move fixture verifier logic out of the core load library and into workload-owned code.
7. Preserve the current runner/CLI contract that a verifier is just an optional callable.

### Non-Goals

1. Redesign `InvariantMonitor` in this round.
2. Introduce a generic verifier framework in `load/lib/load`.
3. Keep the old seq-scan oracle contract in this round.
4. Introduce a new top-level scale field such as `user_count` on `Load::Scale`.
5. Keep the current unrealistic global action semantics for backward compatibility.

## 3. Why This Exists

The fixture is supposed to support an agent-diagnosis exercise that feels like a real multi-tenant app under load. The current workload falls short because its traffic semantics do not match that story:

- app reads are too global
- updates are too synthetic
- tenant count is implied by todo count

That makes the system easier to criticize as “benchmark-shaped” rather than “small app-shaped.”

Separately, the verifier boundary is still too leaky. The workload already owns:

- action semantics
- scale extras
- invariant sampler semantics
- oracle assumptions

Keeping todo-specific verification in the core load library adds abstraction without reducing coupling. This is the wrong trade.

## 4. Scale Contract

`Load::Scale` stays generic. Tenant shape is expressed through `scale.extra`.

For `missing-index-todos`, the workload-specific scale contract becomes:

- `rows_per_table`
- `open_fraction`
- `USER_COUNT`
- any existing workload-specific extras that still matter for batching or cleanup

`USER_COUNT` is the number of tenants/users in the seeded dataset. It is distinct from todo volume.

Example mental model:

- `ROWS_PER_TABLE=100_000`
- `USER_COUNT=1_000`

This yields many fewer users than todos, which is the expected shape for a small multi-tenant todo app.

## 5. Seed Model

`db-specialist-demo` seed logic must start reading `USER_COUNT` from the environment.

The seed contract becomes:

- create exactly `USER_COUNT` users
- distribute todos across those users
- preserve the target open/completed fraction
- keep enough open todos per user that tenant-scoped reads still show meaningful cost

The exact distribution does not need to be perfectly uniform, but it must avoid collapsing into:

- one todo per user
- one user owning almost all todos

The fixture should feel like many users each own a slice of the total todo volume.

## 6. Workload Semantics

All major actions become user-scoped unless they are intentionally app-wide.

### 6.1 `list_open_todos`

`list_open_todos` becomes:

- sample one `user_id` from `1..USER_COUNT`
- issue a request for that user’s open todos

The primary pathology is now:

- “list one tenant’s open todos”
- planner can use the existing `todos.user_id` index to find that tenant slice
- planner still has no better composite access path for `user_id + status + created_at DESC + id DESC`

This is more realistic than listing all open todos across the whole app, but it means the verifier/oracle must stop insisting on a pure seq scan. The intended anti-pattern is now “wrong index for the real tenant query,” not “no index at all.”

### 6.2 `list_recent_todos`

`list_recent_todos` becomes:

- sample one `user_id`
- fetch recent todos for that user
- retain existing page/per-page behavior

This makes “recent todos” consistent with the app’s tenant model instead of behaving like an admin/global listing endpoint.

### 6.3 `search_todos`

`search_todos` becomes:

- sample one `user_id`
- search within that user’s todos only

The text-search/query-shape pathology remains, but it is now exercised in a tenant-shaped way.

### 6.4 `create_todo`

`create_todo` becomes:

- sample one `user_id`
- create a todo for that user

This is already close to the desired model; the important fix is that user ids must come from `USER_COUNT`, not `rows_per_table`.

### 6.5 `close_todo`

`close_todo` becomes a two-step action:

1. fetch one sampled user’s open todos from the app
2. choose one candidate from that returned set
3. issue the close request for that todo

If the chosen user has no open todos, the action is a no-op success, not an error.

This is intentionally more realistic than closing a random global todo id and hoping it exists or is open.

### 6.6 `delete_completed_todos`

`delete_completed_todos` stays direct:

- sample one `user_id`
- issue the delete request for that user’s completed todos
- do not prefetch candidates

The app owns the bounded delete behavior. The workload only chooses the user.

## 7. Demo App API Shape

The JSON API in `db-specialist-demo` should follow the same tenant model.

Expected route shapes:

- `GET /api/todos?user_id=...&status=open|closed|all`
- `GET /api/todos?user_id=...&page=...&per_page=...`
- `GET /api/todos/search?user_id=...&q=...`
- `POST /api/todos` with `user_id`
- `PATCH /api/todos/:id`
- `DELETE /api/todos/completed?user_id=...`

The exact controller signature can differ slightly, but the app contract must clearly express user scope rather than hiding it.

## 8. Verifier Ownership

The verifier should become fully workload-owned.

That means:

- core load library no longer owns `missing-index-todos` fixture verification logic
- workload returns its verifier object through the existing workload hook
- CLI and runner continue to treat a verifier as an optional callable only

This is intentionally **not** a generic “core verifier framework” redesign. The workload already owns the domain knowledge; trying to keep a generic core verifier would just push that same coupling into callback plumbing.

The resulting boundary should be:

- core load library:
  - ask workload for verifier
  - invoke verifier if present
  - classify verifier failure

- workload:
  - define exactly what “fixture is valid” means
  - own explain/count/search checks
  - own any workload-specific data readers or references

For `missing-index-todos`, that verifier contract must explicitly match the tenant-scoped plan shape. The expected open-todos explain is now:

- plan node on `todos` may be `Bitmap Heap Scan`, `Index Scan`, or similar
- access path must rely on `index_todos_on_user_id`
- `Index Cond` / `Recheck Cond` must mention `user_id`
- a remaining `Filter` must still mention `status`
- the plan must still sort for `created_at DESC, id DESC`

That contract keeps the diagnosis exercise honest: the agent still has to identify that the query is under-indexed for its actual access pattern, but the verifier no longer lies about the planner shape.

## 9. Expected Code Shape

After this change, the intended responsibility split is:

- `load/lib/load/workload.rb`
  - generic workload hooks only

- `workloads/missing_index_todos/`
  - workload definition
  - actions
  - invariant sampler
  - verifier
  - oracle

- `load/lib/load/cli.rb`
  - no todo-specific verifier construction logic

- `load/lib/load/fixture_verifier.rb`
  - removed or reduced away entirely in favor of workload-local verifier code

My recommendation is full removal from `load/lib/load`, not a half-generic base class.

## 10. Testing Expectations

The implementation should add or update tests for:

- seed/app contracts reading `USER_COUNT`
- workload scale extras including `USER_COUNT`
- user-scoped request construction for:
  - `list_open_todos`
  - `list_recent_todos`
  - `search_todos`
  - `create_todo`
  - `delete_completed_todos`
- two-step open-todo fetch behavior for `close_todo`
- workload-provided verifier wiring from CLI/runner
- removal of todo-specific verifier assumptions from core load code
- workload-owned verifier/oracle checks matching the tenant-scoped indexed-by-user plan shape

The existing oracle intent should remain green after the reshaping, but its concrete plan assertions must change. The point is to keep the primary diagnosis target while updating it to the tenant-scoped access pattern the app now actually uses.

## 11. Rejected Alternatives

### 11.1 Add `user_count` as a first-class `Load::Scale` field

Rejected because tenant count is not a universal property of every workload. `scale.extra` is the correct place for this workload-specific shape.

### 11.2 Keep a generic core `FixtureVerifier` and push workload checks into callbacks

Rejected because the current code already proves this does not buy enough. It would create more abstraction while keeping the same coupling.

### 11.3 Keep `close_todo` and `delete_completed_todos` both as blind direct writes

Rejected because `close_todo` specifically needs an “open todo” target to feel believable. `delete_completed_todos` does not need the extra fetch and should remain simple.
