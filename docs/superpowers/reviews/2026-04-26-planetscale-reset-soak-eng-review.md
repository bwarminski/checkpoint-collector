# PlanetScale Reset/Soak — Engineering Review

**Branch:** `wip/planetscale` (20 commits ahead of master)
**Plan:** `docs/superpowers/plans/2026-04-26-planetscale-reset-soak.md`
**Design:** `docs/superpowers/specs/2026-04-26-planetscale-reset-soak-design.md`
**Reviewer:** Claude (gstack plan-eng-review, opinionated subset)
**Date:** 2026-04-26

## Verdict

Shippable. Two small follow-ups recommended before merge.

## Plan ↔ implementation alignment

Strong. Both core architectural decisions in the design land as designed:

- Explicit `BENCH_ADAPTER_RESET_STRATEGY=local|remote` env switch (no hostname guessing).
- Generic `log_ingestion_enabled` collector flag (not PlanetScale-specific — reusable for any non-Docker target).

Strategy dispatch in `ResetState#call` is clean. Three live checkpoints (reset, collector, full soak) completed with evidence captured in `JOURNAL.md`. Tests green: reset_state 8/29, runtime_orchestration 4/10, invariant_sampler 3/17.

The checkpoint policy worked — live runs surfaced and fixed three real integration defects not in the plan, each with a TDD cycle:

- `close_todo` JSON envelope mismatch (`{"items":[...]}` vs bare array).
- Verifier HTTP timeout too short for PlanetScale `/api/todos/counts` (5s → 30s).
- Invariant sampler must tolerate `PG::InsufficientPrivilege` on `SET pg_stat_statements.track`.

## Findings

### [P2] (confidence 9/10) `collector/bin/collector:192` — redundant `log_ingestion_enabled:` at executable invocation

The constructor already defaults `log_ingestion_enabled` from `COLLECTOR_DISABLE_LOG_INGESTION` (line 107). Re-passing the same expression at line 192 is duplication of the env-reading logic. Plan prescribed it both places; constructor default makes the executable line dead weight.

**Action:** Drop the `log_ingestion_enabled:` kwarg at line 192. Single source of truth.

### [P2] (confidence 8/10) `adapters/rails/lib/rails_adapter/commands/reset_state.rb:74, 84` — failure messages drop stderr

`raise "schema load failed"` and `raise "seed failed"` discard `schema.stderr` / `load_dataset` error detail. When a PlanetScale reset fails on, e.g., extension privilege, the JSON `error.message` is four words and operators must re-run manually to diagnose. `build_template` has the same pattern.

**Action:** Include stderr in raise messages, e.g. `raise "schema load failed: #{schema.stderr.strip}"`. Forward-compatible with the existing `assert_includes ... "schema load failed"` test.

### [P2] (confidence 8/10) Plan/Makefile drift not reflected in plan

`load-soak-planetscale` target adds `--invariants warn --startup-grace-seconds 60`. Plan Task 7 Step 1 doesn't have these; both were added during checkpoint debugging (justified — Rails boot is slower on PlanetScale; planner stats drift causes false invariant breaches). The journal records the why; the plan file itself was not amended.

**Action:** Update the plan's Task 7 Step 1 Make recipe to match shipped code, OR add a "Deviations from original plan" addendum at the bottom of the plan.

### [P3] (confidence 7/10) `--invariants warn` baked into the only PlanetScale soak target

Silently turns off the abort-on-3-breach safety net for the most fragile environment. Pragmatic now (planner stats unreliable on PlanetScale), but worth flagging.

**Action:** Add a README note calling out this tradeoff. Optional: future `load-soak-planetscale-strict` target once `pg_class.reltuples` behavior on PlanetScale is characterized.

### [P3] (confidence 7/10) `disable_tracking` rescue is narrow

Only catches `PG::InsufficientPrivilege`. Journal confirms that's the actual class PlanetScale raised, so this is fine. Flag only if you see it re-break under a different error class.

**Action:** None now. Re-evaluate if PlanetScale role/permissions change.

### [P3] (confidence 6/10) `reset_remote` does not explicitly truncate before `db:schema:load`

Rails' `db:schema:load` uses `force: :cascade` so existing tables get recreated, but operators familiar with local template-clone semantics may not realize the remote path relies on Rails' destructive load behavior. README correctly says "destructive."

**Action:** None required. Documentation-only concern.

## Test coverage

```
reset_state.rb
  reset_remote (success)               [★★ TESTED]   reset_state_test.rb:46
  reset_remote (schema fail phase)     [★★ TESTED]   reset_state_test.rb:80
  reset_remote (seed fail phase)       [GAP]         symmetric to schema fail, ~15 lines
collector/bin/collector
  log_ingestion_enabled=false          [★★ TESTED]   runtime_orchestration_test.rb:111
  COLLECTOR_DISABLE_LOG_INGESTION env  [GAP]         no test asserts env→flag wiring
invariant_sampler.rb
  disable_tracking permission gone     [★★ TESTED]   invariant_sampler_test.rb:47
```

Two small gaps worth closing:

- Seed-failure phase symmetry (mirrors the schema-fail test).
- Env-var-driven stats-only path. **Becomes moot** if Finding #1 is fixed by removing the duplicate kwarg, since the executable would then exercise the constructor default.

## Recommended follow-up

Two small commits before merge:

1. **Drop the duplicate `log_ingestion_enabled:`** at `collector/bin/collector:192`.
2. **Include stderr in `reset_remote` raise messages** — both schema-load and seed phases (and consider applying to `build_template` for consistency).

Everything else can be tracked as TODO or deferred.
