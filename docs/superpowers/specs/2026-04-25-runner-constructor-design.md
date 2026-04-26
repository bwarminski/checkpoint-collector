# Runner Constructor Design

**Status:** Spec, ready for review
**Date:** 2026-04-25
**Builds on:** `docs/superpowers/specs/2026-04-25-runner-decomposition-design.md`

## 1. Summary

`Load::Runner` now has better internal boundaries than it did before `RunState`, `InvariantMonitor`, and `LoadExecution` were extracted, but its constructor still mixes too many unrelated concerns in one signature.

Today `Runner#initialize` accepts:

- core collaborators
- runtime/test seams
- run configuration
- invariant policy and database dependencies
- verifier wiring
- object-construction logic

That makes the constructor harder to read than the class’s actual job. This change keeps the current behavior, but regroups `Runner` inputs into three domain-shaped value objects:

- `runtime`
- `config`
- `invariant_config`

The goal is not to hide parameters in a generic options hash. The goal is to group them by reason to change so `Runner` reads like a coordinator again.

## 2. Goals and Non-Goals

### Goals

1. Reduce the conceptual width of `Load::Runner#initialize`.
2. Keep the constructor explicit and typed through `Data.define` value objects.
3. Separate runtime seams from operator-facing run settings.
4. Separate invariant-policy setup from general run configuration.
5. Preserve current runtime behavior, CLI behavior, and test seams.
6. Keep `Runner` responsible for building `RunState` and `InvariantMonitor` in this round.

### Non-Goals

1. Introduce a generic `options = {}` constructor.
2. Move verifier construction out of the CLI in this round.
3. Introduce a separate `RunnerFactory` object in this round.
4. Change run artifact schemas, CLI flags, or mode semantics.
5. Change `LoadExecution`, `RunState`, or `InvariantMonitor` behavior.

## 3. Design

### 3.1 Constructor Shape

The new constructor shape is:

```ruby
def initialize(
  workload:,
  adapter_client:,
  run_record:,
  runtime: Runtime.default,
  config: Config.new,
  invariant_config: InvariantConfig.new,
  stderr: $stderr
)
```

This keeps the required domain collaborators explicit:

- `workload`
- `adapter_client`
- `run_record`

Everything else is grouped by purpose.

### 3.2 `Runtime`

`Runtime` owns execution seams that vary by environment or tests:

- `clock`
- `sleeper`
- `http`
- `stop_flag`

`Runtime.default` should be added so production callers do not need to spell out the default seams manually.

Responsibilities:

- provide time
- provide sleep
- provide HTTP transport class
- provide the shared stop flag

This object is not user-facing configuration. It is execution plumbing.

### 3.3 `Config`

`Config` replaces the narrower `Settings` object and owns general run settings:

- `readiness_path`
- `startup_grace_seconds`
- `metrics_interval_seconds`
- `workload_file`
- `app_root`
- `adapter_bin`
- `mode`
- `verifier`

This groups the values that define how one run is supposed to behave from the operator’s perspective.

`verifier` stays here for now. It behaves like an optional run feature, not a runtime seam, and moving it out would make the constructor longer again without enough payoff.

### 3.4 `InvariantConfig`

`InvariantConfig` owns invariant-policy setup:

- `policy`
- `sampler`
- `sample_interval_seconds`
- `database_url`
- `pg`

This separates “how invariants work” from “how the run works.”

The runner should stop doing inline invariant setup logic directly in the constructor body. Instead it should use two small helpers:

- `resolve_invariant_sampler`
- `validate_invariant_sampler!`

That keeps `initialize` focused on construction instead of business rules.

### 3.5 Resulting Runner State

After this change, `Runner` should hold these ivars:

- `@workload`
- `@adapter_client`
- `@runtime`
- `@config`
- `@invariant_config`
- `@stderr`
- `@run_state`
- `@invariant_monitor`

`@run_record` should be removable from `Runner` if it is only needed to build `RunState` and `LoadExecution`.

This does not change the number of moving parts in the system. It changes whether those parts are visible as coherent concepts or as a flat list of loosely related keywords.

## 4. Interaction Model

`Runner` should still construct:

- `RunState`
- `InvariantMonitor`
- `LoadExecution`

but it should derive their inputs from the grouped configs instead of unpacking a long flat constructor signature.

Expected flow:

1. store `workload`, `adapter_client`, `runtime`, `config`, `invariant_config`, `stderr`
2. resolve invariant sampler from `invariant_config`
3. validate invariant setup for continuous mode
4. build `RunState`
5. build `InvariantMonitor`

The constructor should read as setup, not policy evaluation mixed with setup.

## 5. Testing Expectations

The refactor should keep existing behavior locked:

- current CLI tests must still pass
- current runner tests must still pass
- invariant-policy behavior must remain unchanged
- continuous mode still errors when invariants are required and no sampler is available

New focused tests should cover:

- `Runtime.default`
- `Config` defaults
- `InvariantConfig` defaults
- `Runner` still asking the workload for an invariant sampler through `InvariantConfig.database_url` and `InvariantConfig.pg`
- continuous-mode validation behavior after the constructor regrouping

## 6. Rejected Alternatives

### 6.1 Generic options hash

Rejected because it shortens the signature while weakening the meaning of the API.

### 6.2 Separate `RunnerFactory`

Rejected for now because it adds machinery without enough immediate payoff. Grouped value objects solve the main readability problem with a smaller change.

### 6.3 Move verifier out of `Config`

Rejected for this round because it would likely produce:

- `runtime`
- `config`
- `invariant_config`
- `verifier`

That is more semantically pure, but less readable in practice. `verifier` still behaves like a run feature, so it belongs with other run settings for now.
