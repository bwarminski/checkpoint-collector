# InvariantMonitor Design

## Summary

Refactor `Load::InvariantMonitor` so it still owns invariant thread orchestration, but no longer keeps configuration, side-effect plumbing, and mutex-protected mutable state as a flat set of instance variables on one class.

The target shape keeps `InvariantMonitor` as the top-level object and introduces three nested collaborators:

- `Config`
- `Sink`
- `State`

This is a local cleanup. It does not change the public behavior of `run`, `soak`, or `verify-fixture`, and it does not introduce new invariant policies.

## Motivation

`Load::InvariantMonitor` currently has too many instance variables because it owns three separate concerns directly:

1. policy/configuration
2. effect callbacks and `stderr` writes
3. synchronized thread state

That makes the constructor noisy and makes methods like `sample_once` and `sleep_once` harder to read than they need to be.

The goal is not “fewer ivars at any cost.” The goal is to group state by responsibility so the class reads like an orchestrator instead of a bag of fields.

## Goals

1. Keep `Load::InvariantMonitor` as the public orchestration object.
2. Preserve current `off`, `warn`, and `enforce` behavior exactly.
3. Preserve current `Thread.handle_interrupt` scoping and shutdown semantics.
4. Reduce constructor noise and internal ivar sprawl.
5. Make `sample_once` read as policy flow instead of mutex and callback plumbing.

## Non-Goals

1. Introduce new invariant policies.
2. Split policy handling into separate `WarnPolicy` / `EnforcePolicy` classes.
3. Move the nested helpers into top-level files in this round.
4. Change run-record schema or warning/sample payloads.
5. Change runner-facing monitor APIs beyond constructor reshaping that preserves behavior.

## Design

### Top-level shape

`Load::InvariantMonitor` remains the object with the public API:

- `start`
- `stop`
- `sample_once`

It continues to own:

- invariant thread lifecycle
- `Thread.handle_interrupt` scoping
- policy branching
- raising stored failures from `stop`

### Nested `Config`

`Config` is a small value object containing:

- `policy`
- `interval_seconds`

It may provide convenience predicates:

- `off?`
- `warn?`
- `enforce?`

`Config` is passive. It does not perform side effects or hold mutable state.

### Nested `Sink`

`Sink` groups the monitor’s effect endpoints:

- `on_sample`
- `on_warning`
- `on_breach_stop`
- `stderr`

Its job is to make the side effects explicit and local.

Expected methods:

- `sample(sample)`
- `warning(warning_hash)`
- `stderr_warning(message)`
- `stop(reason)`

`Sink` does not decide policy. The monitor still decides when to record a warning, when to print to `stderr`, and when to trigger stop.

### Nested `State`

`State` owns mutable thread state behind a mutex:

- consecutive breach count
- whether the invariant thread is currently sleeping
- stored failure to re-raise from `stop`

Expected methods:

- `with_sleeping { ... }`
- `increment_breaches`
- `reset_breaches`
- `record_failure(error)`
- `clear_failure`

`increment_breaches` returns the new count so threshold checks stay atomic from the caller’s perspective.

`clear_failure` returns the stored failure and nils it under the same lock so repeated `stop` calls do not raise repeatedly.

`State` should be a normal class, not a `Struct`, because it owns synchronization and invariants rather than passive data.

## Constructor shape

The constructor moves from many flat fields to grouped collaborators:

```ruby
Load::InvariantMonitor.new(
  sampler:,
  config: Load::InvariantMonitor::Config.new(
    policy:,
    interval_seconds:
  ),
  stop_flag:,
  sleeper:,
  sink: Load::InvariantMonitor::Sink.new(
    on_sample:,
    on_warning:,
    on_breach_stop:,
    stderr:
  )
)
```

The monitor still directly receives:

- `sampler`
- `stop_flag`
- `sleeper`

Those are true execution dependencies, not configuration bundles.

## Behavior preservation

### `sample_once`

The target control flow remains:

1. sample
2. record sample
3. if healthy:
   - reset consecutive breach count in `enforce`
   - return
4. if breached:
   - record warning
   - print warning to `stderr` in `warn`
   - do not stop in `warn`
   - increment consecutive breaches in `enforce`
   - trigger stop after the third consecutive breach in `enforce`

Representative target shape:

```ruby
def sample_once
  sample = @sampler.call
  @sink.sample(sample)

  unless sample.breach?
    @state.reset_breaches if @config.enforce?
    return sample
  end

  @sink.warning(sample.to_warning)
  @sink.stderr_warning("warning: invariant breach: #{sample.breaches.join('; ')}") if @config.warn?
  return sample unless @config.enforce?

  breaches = @state.increment_breaches
  @sink.stop(:invariant_breach) if breaches >= 3

  sample
end
```

The exact code can differ, but the behavior must stay the same.

### Sleep and shutdown

The thread loop must preserve the current interrupt discipline:

- `Shutdown` is immediate only while sleeping
- `Shutdown` is deferred while running `sample_once`

`sleep_once` should delegate sleeping-state tracking to `State`:

```ruby
def sleep_once
  @state.with_sleeping do
    @sleeper.call(@config.interval_seconds)
  end
end
```

### Failure handling

Sampler failures still behave the same:

- monitor thread records the first failure
- monitor triggers `:invariant_sampler_failed`
- `stop` re-raises once via `Load::InvariantMonitor::Failure`

## Testing requirements

The refactor must preserve existing behavior through the current monitor and runner tests, including:

- warn policy records breaches without aborting
- off policy skips invariant sampling
- enforce policy aborts after three breaches
- stop unblocks the thread while sleeping
- sampler failures propagate as `:invariant_sampler_failed`

Additional focused tests should lock the new helper behavior where useful:

- `State#increment_breaches` returns the new count
- `State#clear_failure` returns-and-clears atomically
- `Sink` methods delegate to the provided callbacks and `stderr`

## Risks

1. Moving state into nested helpers could accidentally change thread semantics if `sleeping` or failure storage is handled differently.
2. Moving side effects into `Sink` could obscure policy ownership if `Sink` starts branching on policy.
3. Over-abstracting the class would make it harder to read than today.

The design avoids these risks by keeping:

- policy branching in `InvariantMonitor`
- helper classes nested
- helper responsibilities narrow

## Acceptance criteria

1. `Load::InvariantMonitor` has materially fewer direct instance variables.
2. `sample_once` reads primarily as policy flow.
3. `start` / `stop` behavior is unchanged.
4. Existing invariant-policy tests remain green.
5. No public behavior changes are required outside constructor call sites.
