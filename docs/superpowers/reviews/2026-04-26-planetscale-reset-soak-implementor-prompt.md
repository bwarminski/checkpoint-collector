# Implementor Prompt — PlanetScale Reset/Soak Review Follow-ups

You implemented `docs/superpowers/plans/2026-04-26-planetscale-reset-soak.md` on `wip/planetscale`. An engineering review found two P2 issues to address before merge, plus an optional plan/doc cleanup.

Full review: `docs/superpowers/reviews/2026-04-26-planetscale-reset-soak-eng-review.md`.

Use TDD where a test would change. Keep diffs minimal — these are cleanups, not redesigns.

## Task A — Remove duplicate `log_ingestion_enabled:` in collector executable

**File:** `collector/bin/collector`

The constructor already defaults `log_ingestion_enabled` from `COLLECTOR_DISABLE_LOG_INGESTION` (around line 107). The executable invocation at line ~192 re-reads the same env var and passes it explicitly. That's a duplicated source of truth — if someone changes one and not the other, the env var stops working.

Drop the `log_ingestion_enabled:` kwarg from the bottom executable `CollectorRuntime.new(...)` call. Let the constructor default handle it.

After the change, add a focused regression test in `collector/test/runtime_orchestration_test.rb` that verifies `COLLECTOR_DISABLE_LOG_INGESTION=1` set in the environment causes `log_ingestion_enabled` to default to `false` when the constructor is called without that kwarg. The existing tests pass the flag explicitly and would not catch a regression in the env-default wiring.

Verify:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby collector/test/runtime_orchestration_test.rb
```

## Task B — Include stderr in `reset_remote` failure messages

**File:** `adapters/rails/lib/rails_adapter/commands/reset_state.rb`

Currently `reset_remote` raises `"schema load failed"` and `"seed failed"` with no captured stderr. When a PlanetScale reset fails (extension privileges, connection trouble, etc.), the JSON `error.message` is four words and operators have to re-run manually to diagnose.

Update both raises in `reset_remote` to include the underlying stderr / error detail. Suggested shape:

```ruby
raise "schema load failed: #{schema.stderr.to_s.strip}" unless schema.success?
```

For the seed phase, `LoadDataset.new(...).call` returns a result hash; surface `result.dig("error", "message")` (or whatever the existing shape exposes — match the contract in `RailsAdapter::Result`).

Apply the same treatment to `build_template` if you want consistency across the local path. Optional but recommended.

The existing `test_reset_state_remote_strategy_reports_schema_load_failure` test asserts `assert_includes ... "schema load failed"`, which remains true with the suffix appended. Add one more assertion that the stderr substring appears in the final message.

Verify:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby adapters/rails/test/reset_state_test.rb
make test-adapters
```

## Task C (optional) — Reflect Makefile drift in the plan

**File:** `docs/superpowers/plans/2026-04-26-planetscale-reset-soak.md`

Task 7 Step 1's Make recipe in the plan does not include `--invariants warn --startup-grace-seconds 60`, but the shipped Makefile target does. Either:

- Update the plan's recipe to match shipped code, OR
- Add a short "Deviations from plan" section at the bottom referencing the journal entries that explain why those flags were necessary on PlanetScale (slow Rails boot, planner-stat drift triggering false invariant breaches).

This is a documentation cleanup so future readers can diff plan vs. ship without confusion.

## Out of scope

- Broadening the `PG::InsufficientPrivilege` rescue (re-evaluate if it re-breaks).
- Adding a `load-soak-planetscale-strict` target.
- Adding an explicit truncate before `db:schema:load`.

These are flagged P3 in the review and tracked as documentation/future-work items.

## Commit guidance

Two commits, one per task (A and B). Task C optional, can be folded into either or skipped. Conventional `fix:` / `docs:` prefixes consistent with branch history.
