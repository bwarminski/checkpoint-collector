# InvariantMonitor Cleanup Plan

## Summary

Refactor `Load::InvariantMonitor` so it stays the orchestration object but groups its responsibilities into three nested collaborators:

- `Config`
- `Sink`
- `State`

The work is intentionally local. It should preserve current `warn`, `off`, and `enforce` behavior, keep the current thread-interrupt discipline, and avoid broad runner changes beyond the constructor call site.

## Constraints

1. Preserve current public behavior.
2. Preserve current test coverage for invariant policy behavior.
3. Keep policy branching in `InvariantMonitor`.
4. Keep helpers nested inside `InvariantMonitor`.
5. Make the smallest reasonable code changes.

## Task 1: Lock current behavior with focused monitor tests

### Step 1. Add or tighten focused tests around helper-worthy behavior

Add focused tests in `load/test/invariant_monitor_test.rb` that pin the behaviors this refactor must preserve and that map cleanly onto the new helper boundaries.

Required coverage:

- `sample_once` returns a healthy sample and resets breaches in `enforce`
- `sample_once` records a warning and prints to `stderr` in `warn`
- `sample_once` records a warning and triggers stop after the third consecutive breach in `enforce`
- `stop` re-raises only one stored sampler failure
- `stop` unblocks a sleeping thread cleanly

Add focused assertions for the future `State` responsibilities where useful:

- breach counter increments return the new count
- stored failure is cleared after one raise path
- `Sink` delegates `sample`, `warning`, `stderr_warning`, and `breach_stop` without any policy branching

Do not rewrite the existing broad behavior tests if a narrower addition is enough.

For the current sleeping-path test at `load/test/invariant_monitor_test.rb:103`, do not rely on `instance_variable_set(:@sleeping, true)` after the refactor. Restructure that test to drive the real sleep path instead of mutating a flat ivar that will move into `State`.

### Step 2. Run the focused test file and confirm failure first if new tests were added

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/invariant_monitor_test.rb
```

Pass criteria for the red step:

- new tests fail for the expected reason
- no unrelated failures appear

## Task 2: Introduce nested Config, Sink, and State

### Step 1. Add nested `Config`

Inside `Load::InvariantMonitor`, add a nested `Config` value object that owns:

- `policy`
- `interval_seconds`

Add convenience predicates:

- `off?`
- `warn?`
- `enforce?`

### Step 2. Add nested `Sink`

Inside `Load::InvariantMonitor`, add a nested `Sink` value object that owns:

- `on_sample`
- `on_warning`
- `on_breach_stop`
- `stderr`

Give it small delegation methods:

- `sample(sample)`
- `warning(warning_hash)`
- `stderr_warning(message)`
- `breach_stop(reason)`

`Sink` must not branch on policy.

### Step 3. Add nested `State`

Inside `Load::InvariantMonitor`, add a nested `State` class that owns:

- consecutive breaches
- sleeping flag
- stored failure
- mutex

Add methods:

- `with_sleeping`
- `increment_breaches`
- `reset_breaches`
- `record_failure`
- `clear_failure`

Keep the threshold decision in `InvariantMonitor`: `increment_breaches` must return the new count so the monitor remains the place that decides whether `>= 3` triggers `:invariant_breach`.

`clear_failure` must preserve the current atomic return-and-clear behavior.

`with_sleeping` must not introduce its own `Thread.handle_interrupt` block. Its body should only toggle the sleeping flag around `yield`:

```ruby
def with_sleeping
  @mutex.synchronize { @sleeping = true }
  yield
ensure
  @mutex.synchronize { @sleeping = false }
end
```

### Step 4. Change the constructor to grouped inputs

Refactor `Load::InvariantMonitor.new` to take:

- `sampler:`
- `config:`
- `stop_flag:`
- `sleeper:`
- `sink:`

Remove the flat constructor fields that are now grouped into `Config` and `Sink`.

### Step 5. Migrate every constructor call site to the grouped shape

Update all flat-shape constructor call sites to the grouped shape:

- `load/test/invariant_monitor_test.rb:12`
- `load/test/invariant_monitor_test.rb:34`
- `load/test/invariant_monitor_test.rb:52`
- `load/test/invariant_monitor_test.rb:70`
- `load/test/invariant_monitor_test.rb:92`
- `load/test/invariant_monitor_test.rb:113`
- `load/lib/load/runner.rb:92-102`

At those sites:

- build `Load::InvariantMonitor::Config.new(policy:, interval_seconds:)`
- build `Load::InvariantMonitor::Sink.new(on_sample:, on_warning:, on_breach_stop:, stderr:)`
- keep `sampler:`, `stop_flag:`, and `sleeper:` flat

For `load/test/invariant_monitor_test.rb:103`, restructure the test to drive the real sleep path instead of adding a special accessor for `State`.

### Step 6. Update `Load::Runner` call site

Update `load/lib/load/runner.rb` so monitor construction uses:

- `Load::InvariantMonitor::Config.new(...)`
- `Load::InvariantMonitor::Sink.new(...)`

Do not change runner behavior beyond the constructor call shape.

### Step 7. Run focused tests and existing invariant runner locks

The `test_runner_off_policy_skips_invariant_sampling` lock already exists by name in `load/test/runner_test.rb`, so keep using that exact name in the verification commands.

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/invariant_monitor_test.rb
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb --name test_runner_warn_policy_records_breaches_without_aborting
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb --name test_runner_off_policy_skips_invariant_sampling
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb --name test_runner_aborts_after_three_consecutive_invariant_breaches
```

Pass criteria:

- focused monitor tests are green
- the key runner regression tests are green

## Task 3: Move internal monitor logic onto the helpers

### Step 1. Rewrite `sample_once` around `Config`, `Sink`, and `State`

Refactor `sample_once` so it reads as policy flow:

1. sample
2. record sample
3. if healthy:
   - reset breaches in `enforce`
   - return
4. if breached:
   - record warning
   - print warning in `warn`
   - return in `warn`
   - increment breaches in `enforce`
   - call `@sink.breach_stop(:invariant_breach)` on threshold

Keep policy branching inside the monitor.

### Step 2. Rewrite sleep tracking around `State#with_sleeping`

Remove direct sleeping-flag mutation from the monitor and move it into `with_sleeping`.

Preserve the current `Thread.handle_interrupt` discipline:

- immediate only during sleep
- deferred during `sample_once`

`State#with_sleeping` must only toggle sleeping state around `yield`. It must not add interrupt handling of its own.

### Step 3. Rewrite failure handling around `State#record_failure` and `clear_failure`

When the sampler thread raises unexpectedly:

- record the first failure in `State`
- trigger `:invariant_sampler_failed`

When `stop` runs:

- preserve the current clear-and-raise-once behavior
- do not raise again on repeated `stop` calls

### Step 4. Delete dead flat ivars and helper code

Delete flat monitor state that is now represented by `Config`, `Sink`, and `State`.

Expected removals include direct monitor ivars for:

- policy
- interval
- side-effect callbacks
- `stderr`
- consecutive breach count
- sleeping flag
- failure mutex plumbing

### Step 5. Run focused tests again, then broader load tests

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/invariant_monitor_test.rb
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby -e 'Dir["load/test/*_test.rb"].sort.each { |path| load path }'
```

Pass criteria:

- monitor tests green
- runner tests green
- load suite green

## Task 4: Final cleanup and verification

### Step 1. Verify constructor and ivar cleanup directly

Inspect the final `load/lib/load/invariant_monitor.rb` and confirm the class now reads as an orchestrator over the three nested helpers.

Run:

```bash
sed -n '1,260p' load/lib/load/invariant_monitor.rb
```

### Step 2. Run the full local gate

Run:

```bash
make test
```

Pass criteria:

- load suite green
- adapters suite green
- workloads suite green

### Step 3. Run hygiene checks

Run:

```bash
git diff --check
```

Pass criteria:

- `git diff --check` is clean

## Risks

1. A small helper extraction could accidentally change interrupt scoping.
2. Failure propagation could regress if `clear_failure` is not atomic.
3. Moving warning output into `Sink` could accidentally move policy branching out of the monitor.

## Self-review checklist

Before declaring the work done, verify:

- `InvariantMonitor` still owns thread lifecycle and policy flow
- `Config` is passive
- `Sink` is effect-only and does not branch on policy
- `State` owns synchronized mutable fields
- `warn`, `off`, and `enforce` behavior remain unchanged
- repeated `stop` does not re-raise the same stored failure
- `Thread.handle_interrupt` behavior is preserved
- every flat-shape constructor call site was migrated
- `Sink#breach_stop` naming is consistent
