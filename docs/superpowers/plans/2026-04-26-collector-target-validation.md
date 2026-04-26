# Collector Target Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add repeatable collector validation targets for local Postgres and PlanetScale-backed Postgres.

**Architecture:** Implement one collector validator class that runs a harmless marker query, executes one existing `CollectorRuntime#run_once_pass`, and verifies ClickHouse received fresh `collector_state` and marker `query_events` rows. Add a tiny CLI wrapper and make targets that configure local Postgres versus PlanetScale mode without duplicating validation logic.

**Tech Stack:** Ruby, Minitest, PG, Net::HTTP ClickHouse SQL API, Make.

---

## File Map

- Create `collector/lib/collector_target_validator.rb`: owns validation query, ClickHouse baseline checks, stats-only enforcement, and one-pass runtime invocation.
- Create `collector/test/collector_target_validator_test.rb`: fake-driven validator coverage.
- Create `bin/collector-validate`: CLI wrapper that loads `collector/bin/collector` for `CollectorRuntime`, runs the validator, and prints success/failure.
- Modify `Makefile`: add `validate-collector-postgres` and `validate-collector-planetscale`.
- Modify `load/test/load_smoke_target_test.rb`: lock the make targets.
- Modify `README.md`: document how to validate collector wiring before local or PlanetScale soak.
- Modify `JOURNAL.md`: record implementation notes and verification.

## Task 1: Add Validator Unit Coverage

**Files:**
- Create: `collector/test/collector_target_validator_test.rb`

- [ ] **Step 1: Write failing tests**

Create tests for successful validation, missing env/config, stats-only enforcement, missing `collector_state` advancement, and missing marker query evidence. Use fakes for PG, runtime, and ClickHouse query transport.

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby collector/test/collector_target_validator_test.rb
```

Expected: fails because `collector/lib/collector_target_validator` does not exist.

## Task 2: Implement Validator

**Files:**
- Create: `collector/lib/collector_target_validator.rb`

- [ ] **Step 1: Add validator implementation**

Implement `CollectorTargetValidator` with:

- `VALIDATION_COMMENT = "collector_target_validation"`
- `VALIDATION_SQL = "SELECT 1 /* collector_target_validation */"`
- `Error = Class.new(StandardError)`
- initializer kwargs for `postgres_url:`, `clickhouse_url:`, `require_stats_only:`, `env:`, `pg:`, `runtime_factory:`, and `clickhouse_query:`
- `call` returning a hash with `ok`, `collector_state_before`, `collector_state_after`, `query_events_before`, and `query_events_after`
- clear errors for missing URLs, stats-only mismatch, unreadable `pg_stat_statements`, no collector-state advancement, and no marker query evidence

- [ ] **Step 2: Run validator tests**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby collector/test/collector_target_validator_test.rb
```

Expected: all tests pass.

- [ ] **Step 3: Commit validator**

```bash
git add collector/lib/collector_target_validator.rb collector/test/collector_target_validator_test.rb
git commit -m "feat: add collector target validator"
```

## Task 3: Add CLI and Make Targets

**Files:**
- Create: `bin/collector-validate`
- Modify: `Makefile`
- Modify: `load/test/load_smoke_target_test.rb`

- [ ] **Step 1: Write failing Makefile test**

Update `load/test/load_smoke_target_test.rb` to assert:

- `.PHONY` includes `validate-collector-postgres` and `validate-collector-planetscale`
- `validate-collector-postgres` runs `bin/collector-validate`
- `validate-collector-planetscale` sets `COLLECTOR_DISABLE_LOG_INGESTION=1`
- the PlanetScale target uses `BENCH_ADAPTER_PG_ADMIN_URL` when present

- [ ] **Step 2: Run test and verify failure**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/load_smoke_target_test.rb
```

Expected: fails because the targets do not exist.

- [ ] **Step 3: Add CLI and Make targets**

`bin/collector-validate` should:

- load `collector/bin/collector`
- require `collector/lib/collector_target_validator`
- build a validator from env
- print a concise pass line
- print validation errors to stderr and exit non-zero

`Makefile` should add:

- `validate-collector-postgres`
- `validate-collector-planetscale`

- [ ] **Step 4: Run target tests**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/load_smoke_target_test.rb
```

Expected: pass.

- [ ] **Step 5: Commit CLI and Make targets**

```bash
git add bin/collector-validate Makefile load/test/load_smoke_target_test.rb
git commit -m "feat: add collector validation targets"
```

## Task 4: Documentation and Verification

**Files:**
- Modify: `README.md`
- Modify: `JOURNAL.md`

- [ ] **Step 1: Document validation commands**

Add local and PlanetScale collector validation examples near the existing local and PlanetScale operator docs.

- [ ] **Step 2: Run test suites**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby collector/test/collector_target_validator_test.rb
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/load_smoke_target_test.rb
make test-load
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby -e 'Dir["collector/test/*_test.rb"].sort.each { |path| load path }'
```

Expected: all pass.

- [ ] **Step 3: Optional live validation**

If local ClickHouse/Postgres are running, run:

```bash
CLICKHOUSE_URL=http://localhost:8123 \
POSTGRES_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo \
make validate-collector-postgres
```

If PlanetScale env is exported, run:

```bash
CLICKHOUSE_URL=http://localhost:8123 \
POSTGRES_URL="$BENCH_ADAPTER_PG_ADMIN_URL" \
make validate-collector-planetscale
```

- [ ] **Step 4: Commit docs**

```bash
git add README.md JOURNAL.md
git commit -m "docs: document collector validation"
```

## Self-Review

- Spec coverage: the plan covers one shared validator, local and PlanetScale make targets, deterministic marker SQL, stats-only enforcement, tests, docs, and live validation hooks.
- Placeholder scan: no placeholders remain.
- Type consistency: the plan consistently uses `CollectorTargetValidator`, `POSTGRES_URL`, `CLICKHOUSE_URL`, `COLLECTOR_DISABLE_LOG_INGESTION`, `validate-collector-postgres`, and `validate-collector-planetscale`.
