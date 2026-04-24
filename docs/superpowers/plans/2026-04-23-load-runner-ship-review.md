# Ship review — 2026-04-23

**Branch:** `wip/fixture-harness-plan` at commit `9d1bfe4`
**Base:** `origin/master`
**Diff:** 99 files, +14,627/-101
**Verdict:** `DO_NOT_SHIP`

Ship was invoked after three `plan-eng-review` rounds had cleared residuals. The ship skill's Step 9 auto-review (5 specialists + Claude adversarial + Codex adversarial) surfaced three ship-blockers the prior rounds missed, all centered on benchmark fidelity and silent-corruption risk. Ship was aborted before the VERSION bump.

## Reviewer sources
- **Codex adversarial** — `DO_NOT_SHIP`, found P0.1 (template cache)
- **Claude adversarial** — `SHIP_WITH_FIXES`, found reporter final-interval mislabeling
- **Performance specialist** — 2× CRITICAL (confidence 10) on rate limiter + HTTP client; CRITICAL (confidence 9) on tracking buffer
- **Testing specialist** — 10 coverage-gap findings (negative-path, error-path, edge-cases)
- **Maintainability specialist** — 10 findings (dead code, magic numbers, stale ABOUTMEs)
- **API-contract specialist** — 10 findings (spec↔impl drift on reset-state, migrate, run.json, bin/load flags)
- **Security specialist** — 5 findings (identifier interpolation, secret logging in adapter-commands.jsonl, unvalidated adapter response shapes)
- **Codex structured** — timed out with no output; do not re-run, the other reviewers covered it

## P0 — ship-blocking

### P0.1 — TemplateCache key ignores scale/seed parameters

**Files:**
- `adapters/rails/lib/rails_adapter/template_cache.rb:60-65` (`template_name` builds from `database_name` + 12-char schema SHA256 only)
- `adapters/rails/lib/rails_adapter/commands/reset_state.rb:37-42` (clone-hit short-circuits, seed runner only runs inside `build_template` on miss)
- `workloads/missing_index_todos/workload.rb:15` (passes `ROWS_PER_TABLE=10_000_000`, `OPEN_FRACTION=0.002`, `SEED=42` via `--env`)

**Failure scenario:**
1. Run A seeds template with `ROWS_PER_TABLE=1_000`, `OPEN_FRACTION=0.2`, `SEED=7`.
2. Run B (same schema digest) passes `ROWS_PER_TABLE=10_000_000`, `OPEN_FRACTION=0.002`, `SEED=42`.
3. `template_exists?` is true → `clone_template` restores the 1k-row dataset → seed step skipped.
4. Runner proceeds, emits latency + query-volume metrics for the wrong dataset.
5. Oracle `PASS: explain (Seq Scan)` may still hold directionally, but `PASS: clickhouse (N calls)` reflects a tiny dataset instead of a big one.

**Fix:** include a digest of seed-affecting env vars (`SEED`, `ROWS_PER_TABLE`, `OPEN_FRACTION`, and any future workload-specific env) in `template_name`. Concretely:

```ruby
def template_name(database_name, app_root:, seed_env: {})
  digest = schema_digest(app_root)
  seed_hash = Digest::SHA256.hexdigest(seed_env.sort.to_a.to_s)[0, 8]
  prefix = database_name[0, IDENTIFIER_LIMIT - TEMPLATE_SUFFIX_LENGTH - 9]
  "#{prefix}_tmpl_#{digest}_#{seed_hash}"
end
```

Caller flow in `reset_state.rb`: thread the seed-affecting subset of `@env_pairs` into `template_exists?` / `build_template` / `clone_template` via a shared param. Re-check `TEMPLATE_SUFFIX_LENGTH` math so the 63-char Postgres identifier limit still holds.

**TDD test** (write first, watch fail, then fix):
- `template_cache_test.rb` — two calls with the same `database_name` + `app_root` but different seed-env hashes produce different `template_name` values.
- `reset_state_test.rb` — given an existing template for seed-env A, calling reset-state with seed-env B rebuilds the template instead of cloning.

---

### P0.2 — `RateLimiter` holds its mutex across the sleep

**File:** `load/lib/load/rate_limiter.rb:15-25`

```ruby
def wait_turn
  @mutex.synchronize do
    return if @rate_limit == :unlimited
    now = @clock.call
    @next_allowed_at ||= now
    sleep_for = @next_allowed_at - now
    @sleeper.call(sleep_for) if sleep_for.positive?                    # ← inside the lock
    @next_allowed_at = [@next_allowed_at, now].max + (1.0 / @rate_limit)
  end
end
```

Every worker calling `wait_turn` serializes behind the one currently sleeping. Effective throughput ≤ `rate_limit` regardless of worker count. The limiter is the bottleneck shaping every measurement.

**Fix pattern:**

```ruby
def wait_turn
  return if @rate_limit == :unlimited

  target =
    @mutex.synchronize do
      now = @clock.call
      @next_allowed_at ||= now
      t = [@next_allowed_at, now].max
      @next_allowed_at = t + (1.0 / @rate_limit)
      t
    end

  wait = target - @clock.call
  @sleeper.call(wait) if wait.positive?
end
```

**TDD test:** the existing `test_shared_rate_limit_holds_across_multiple_workers` passes because it uses a fake sleeper that advances a shared clock — the mutex bug is invisible under that fake. Add a test where the sleeper is a real `sleep` (or a fake that records wall-clock ordering) and the test asserts workers are not serialized by the limiter's lock. Concretely, assert that total elapsed wall time with N workers ≈ single-worker time, not N× single-worker time.

Also drop the stale ABOUTME on line 2 ("Preserves the limiter timing behavior used by the fixture harness").

---

### P0.3 — `Load::Client` opens a fresh TCP connection per request

**File:** `load/lib/load/client.rb:15-27`

`@http.start(uri.host, uri.port, ...) do |http| ... end` opens a new connection every call. At target request rates, connect + TLS (if any) + TIME_WAIT accumulation dominate measured latency and limit throughput in ways unrelated to the system under test.

**Fix:** one long-lived `Net::HTTP` instance per worker, started once, used for all requests in the worker's run.

```ruby
# in Load::Client (or a new Load::PersistentClient)
def initialize(base_url:, http: Net::HTTP)
  @base_url = URI(base_url)
  @http = http
  @conn = nil
end

def start
  @conn = @http.new(@base_url.host, @base_url.port)
  @conn.use_ssl = @base_url.scheme == "https"
  configure_timeouts(@conn)
  @conn.keep_alive_timeout = 30
  @conn.start
  self
end

def finish
  @conn&.finish
  @conn = nil
end

def request(method, path)
  uri = uri_for(path)
  request_class = Net::HTTP.const_get(method.to_s.capitalize)
  @conn.request(request_class.new(uri))
end
```

Wiring: each worker owns its own `Load::Client` instance, calls `start` before the loop, `finish` in an `ensure`. The readiness probe stays on a short-lived client (it's one-shot and runs before workers spin up).

**TDD tests:**
- Each worker's `Load::Client` keeps the same underlying connection across requests (mock `Net::HTTP.new` and assert it's called once per worker, not once per request).
- `finish` runs even if the worker raises mid-loop.

---

## P1 — fidelity regression (fix before next ship attempt)

### P1.1 — `TrackingBuffer` grabs `@state_mutex` on every request

**File:** `load/lib/load/runner.rb:221-234, 265-278` (tracking-buffer + `record_request_ok` / `record_request_error`)

Each worker's `record_ok` / `record_error` callback invokes `@state_mutex.synchronize` in the runner to bump a shared counter. All workers serialize on that mutex for a trivial increment on the per-request path.

**Fix:** per-worker counters, aggregated at snapshot time. Or atomic counters (`Concurrent::AtomicFixnum` or a lock-free ring).

**TDD test:** worker request counter increments are not observed by other workers until a snapshot boundary (or are observed via an atomic primitive with no lock contention).

---

## P2 — correctness / integrity nits

### P2.1 — Reporter final-interval `interval_ms` may not reflect actual elapsed time

**File:** `load/lib/load/reporter.rb` (snapshot + stop flow)

Claude adversarial's finding: the final `metrics.jsonl` line emitted during `stop` is stamped with the configured `interval_ms` even though its payload covers whatever time elapsed since the last periodic snapshot (possibly less than, or more than, the interval).

Verify by inspection — if true, downstream throughput calculations for the last bucket lie. Fix by computing actual elapsed time from `@clock.call - @last_snapshot_ts` for the final flush and emitting that as `interval_ms`.

### P2.2 — `TemplateCache` interpolates `database_name` into raw SQL

**File:** `adapters/rails/lib/rails_adapter/template_cache.rb:24, 35-36`

`CREATE DATABASE #{template_name(database_name, ...)} TEMPLATE #{database_name}` uses raw string interpolation. `database_name` comes from `BENCHMARK_DB_NAME` or the path of `DATABASE_URL`, neither validated as a Postgres identifier. A malformed env value breaks SQL; a malicious one can inject. Low real-world risk, easy to tighten.

**Fix:** validate against `/\A[a-zA-Z_][a-zA-Z0-9_]{0,62}\z/` before interpolation, or use `PG::Connection#quote_ident`.

### P2.3 — adapter-commands.jsonl may log `DATABASE_URL` password

**File:** `load/lib/load/adapter_client.rb:47-61` (`append_adapter_command` captures full `stderr`)

If any child process crashes and echoes the `DATABASE_URL` (which includes the password in its URL), the password lands in plaintext in `runs/<run_id>/adapter-commands.jsonl`. Run artifacts are the kind of thing you'd share or archive.

**Fix:** redact `password:...@` in the logged `stderr` before write. Same for any `--env` payload — we already pass-through `--env KEY=VALUE` unmodified into the adapter argv logging. Redact keys matching `*_URL`, `*_PASSWORD`, `*_TOKEN`, `*_KEY`, `*_SECRET`.

### P2.4 — spec↔impl drift cluster

Each of these is a separate small item. Fix each by updating the spec if the new behavior is intentional, or updating the code to match the spec.

| Finding | Location | Decision |
|---|---|---|
| `migrate` runs `db:schema:load`, spec §5.2 says `db:migrate` | `adapters/rails/lib/rails_adapter/commands/migrate.rb:12`; `docs/superpowers/specs/2026-04-19-load-forge-mvp-design.md` §5.2 | Update spec to say `db:schema:load` (matches current impl + journal entry on schema canonicalization) |
| `reset-state` has undocumented `--workload` flag and returns undocumented `query_ids` | `adapters/rails/lib/rails_adapter/commands/reset_state.rb:26,47`; spec §5.2 | Update spec §5.2 to document both |
| `run.json` has undocumented top-level `query_ids` and `outcome.error_code` | `load/lib/load/runner.rb:262-292`; spec §9.1 | Update spec §9.1 |
| `bin/load` missing `--debug-log <path\|->` that spec §12 lists | `load/lib/load/cli.rb`; spec §12 | Either implement or remove from spec |
| No `schema_version` in `run.json` | `load/lib/load/run_record.rb`; spec §9.1 | Add `schema_version: 1` to initial state, document in spec |

### P2.5 — dead-looking adapter commands

**Files:** `adapters/rails/lib/rails_adapter/commands/load_dataset.rb`, `adapters/rails/lib/rails_adapter/commands/migrate.rb`

Neither appears to be invoked by the runner. `ResetState#build_template` seeds the DB itself (same `load db/seeds.rb` call). Either delete both (and their bench-adapter dispatch entries + tests), or wire them into `ResetState` so there's no duplication.

### P2.6 — stale ABOUTMEs referencing the removed fixture harness

**Files:**
- `load/lib/load/rate_limiter.rb:2` ("Preserves the limiter timing behavior used by the fixture harness.")
- `workloads/missing_index_todos/README.md:6` ("...at the same scale as the fixture harness it replaces")

Per CLAUDE.md: comments must not carry temporal or migration context. Replace with evergreen descriptions.

---

## P3 — nits (fix whenever)

- `adapters/rails/lib/rails_adapter/command_runner.rb:14` — `command_name:` kwarg accepted but unused.
- `rails_env` helper duplicated across 5 Commands classes — extract a `Commands::Base`.
- `load/lib/load/worker.rb:20` — `started_ns = monotonic_ns` assignment unread.
- `load/lib/load/runner.rb` — magic numbers (`WORKER_DRAIN_TIMEOUT_SECONDS` is named; `1.0` poll interval, default `startup_grace_seconds: 15`, `metrics_interval_seconds: 5` are bare).
- `load/lib/load/readiness_gate.rb` — backoff constants `0.2`, `1.6`, `2` unnamed.
- `adapters/rails/lib/rails_adapter/commands/start.rb:14` + `port_finder.rb:8` — port range `3000..3020` duplicated.
- `adapters/rails/lib/rails_adapter/result.rb:26` (`Result.wrap.classify`) — derives error code from exception class name via string-munge (`Errno::ENOENT → "e_n_o_e_n_t"`); spec wants stable short strings.
- `Reporter` snapshot (`metrics.rb:67`) — sorts the same latency array twice per percentile; fold into one sort.
- Oracle's ClickHouse polling opens a fresh HTTP connection every tick (oracle.rb:168).

---

## Testing gaps worth filling alongside the P0 fixes

These came from the Testing specialist — worth the implementor's attention when writing the regression tests for the P0s above.

- `adapter_client.rb:62,65` — no test for `exit!=0 + empty stderr` and no test for JSON-parse failure on a failing-exit invocation.
- `readiness_gate.rb:40` — no test for transient `Errno::ECONNREFUSED` → eventual success (tests only cover HTTP 500 loops and path=none).
- `readiness_gate.rb:69` — exponential backoff cap at 1.6s is untested.
- `runner.rb:66` — `reset_state` responses that are non-Hash, or Hash without `query_ids`, leave `state.query_ids = []`. Untested.
- `run_record.rb:30` — `File.rename` failure (permission, ENOSPC) leaves a `.tmp` file; no cleanup test.
- `reporter.rb:43` — sink raising inside `snapshot_once` kills the reporter thread silently; `stop` then joins a dead thread. Undefined contract.
- `stop.rb:30` — `alive_within?` only rescues `Errno::ESRCH`. `Errno::EPERM` propagates.
- `rate_limiter.rb:23` — `rate_limit: 0` would divide by zero; negative values nonsensical. No input validation.

---

## Suggested fix order (smallest blast radius first)

1. **P0.2 `RateLimiter` mutex** — 15 lines, self-contained, existing test barely needs changes.
2. **P0.3 `Load::Client` persistent connection** — ~40 lines across client.rb + worker wiring, new lifecycle tests.
3. **P0.1 `TemplateCache` seed-env digest** — threads a new param through 3-4 call sites, integration test for build-vs-clone hit.
4. **P1.1 `TrackingBuffer` shared mutex** — refactor, per-worker counters + snapshot aggregation.
5. **P2.1 reporter final-interval `interval_ms`** — verify first, then fix.
6. **P2.2–P2.6** — in whatever order. These are individually small.
7. **P3** — post-ship cleanup batch.

## Re-review gate

After the three P0s land, re-run `/plan-eng-review` (round 4) with specific focus on:
- Reading the new TemplateCache tests under concurrent build/clone contention.
- Verifying `RateLimiter` under real `sleep` (not just fake sleeper).
- Verifying `Load::Client` reuses connections across worker iterations and cleans up in `ensure`.
