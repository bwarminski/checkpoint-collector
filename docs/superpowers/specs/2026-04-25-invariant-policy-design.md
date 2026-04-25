# ABOUTME: Specifies configurable invariant handling for load runner run and soak modes.
# ABOUTME: Defines enforce, warn, and off policies without changing fixture verification behavior.

# Invariant Policy Design

## Summary

Add a shared CLI flag to `bin/load run` and `bin/load soak`:

```text
--invariants enforce|warn|off
```

The default stays `enforce`.

The goal is to let operators keep or relax the invariant sampler depending on the task:

- `enforce` preserves the current canonical behavior
- `warn` keeps invariant visibility without forcing shutdown
- `off` disables invariant sampling entirely

`bin/load verify-fixture` is unchanged. It does not use the invariant sampler.

## Motivation

The current fixture uses the invariant sampler as a safety rail during `soak`. That is correct for the canonical workload, but it is too rigid for operator tasks like:

- exploratory testing
- long diagnosis sessions
- experiments that intentionally let the dataset drift
- benchmarking where invariant shutdown is not the desired control plane

Operators need a small, explicit way to choose whether invariant breaches abort the run, only warn, or stay out of the way.

## Behavior Contract

### `enforce`

`enforce` is the default and preserves current behavior:

- start the invariant sampler thread
- append samples to `run.json.invariant_samples`
- append breach entries to `run.json.warnings`
- abort the run after three consecutive breached samples
- write `outcome.error_code: "invariant_breach"` when the run aborts for this reason

### `warn`

`warn` keeps the sampler active but changes breach handling:

- start the invariant sampler thread
- append samples to `run.json.invariant_samples`
- append breach entries to `run.json.warnings`
- write one concise line to `stderr` for each breached sample
- never abort the run because of invariant breaches

Other stop reasons still behave normally. For example, `sigint`, `sigterm`, adapter failures, and readiness failures are unchanged.

### `off`

`off` disables the invariant sampler for the run:

- do not construct or start the invariant sampler thread
- do not append `invariant_samples` from this mechanism
- do not append invariant-breach warnings from this mechanism
- never stop the run because of invariant breaches

The run still records the `warnings` and `invariant_samples` keys in `run.json`; they simply remain empty unless some other mechanism writes to them in the future.

## CLI Contract

### Commands

The flag is supported on:

- `bin/load run`
- `bin/load soak`

It is not supported on:

- `bin/load verify-fixture`

### Parsing

Accepted values:

- `enforce`
- `warn`
- `off`

If the user passes any other value, CLI parsing fails with a usage error.

If the user omits the flag, the effective value is `enforce`.

## Implementation Shape

### CLI

`Load::CLI` parses `--invariants` as a shared run option and passes the resolved value into the runner factory.

The runner factory passes that value into `Load::Runner`.

### Runner

`Load::Runner` receives one new setting: `invariant_policy`.

Policy ownership stays in the runner. The sampler remains responsible only for reading database counts and returning `InvariantSample`.

The policy affects two places:

1. whether the invariant thread starts at all
2. what the runner does when a sampled invariant breaches

#### Thread startup

- `off`: do not start the invariant thread
- `enforce` and `warn`: start the existing invariant thread

#### Breach handling

When a sample breaches:

- always append the sample record if sampling is enabled
- always append a warning record if sampling is enabled
- in `warn`, also write one line to `stderr`
- only in `enforce` does the runner increment the consecutive-breach counter and trigger stop after three consecutive breaches

Healthy samples continue to reset the consecutive-breach counter in `enforce`.

## Output Contract

### `run.json`

When policy is `enforce` or `warn`:

- `invariant_samples` grows on the normal sampling interval
- `warnings` grows when breaches occur

When policy is `off`:

- `invariant_samples` remains empty
- `warnings` receives no entries from invariant sampling

### `stderr`

Only `warn` writes operator-facing invariant breach lines to `stderr`.

The line should be concise and include enough context to diagnose the breach without reading `run.json`, for example:

```text
warning: invariant breach: open_count 120 is below open_floor 30000
```

Exact formatting can follow existing CLI style, but it must stay one line per breach.

## Testing

Add focused coverage for:

- CLI default behavior: omitted flag resolves to `enforce`
- CLI parsing: `warn` and `off` are accepted; invalid values fail
- runner `warn` behavior:
  - samples are recorded
  - warnings are recorded
  - repeated breaches do not abort the run
  - breached samples emit `stderr` lines
- runner `off` behavior:
  - invariant sampler is not started
  - no invariant samples are recorded
  - no invariant-breach warnings are recorded

Existing `enforce` tests should stay green without semantic changes. They remain the regression proof that the default contract did not drift.

## Documentation

Update the operator docs to describe:

- the new `--invariants` flag
- the three policy values
- the fact that `verify-fixture` does not use invariant sampling
- the operator tradeoff: `warn` preserves visibility while allowing degraded runs to continue

## Non-Goals

This change does not:

- add custom warning frequency controls
- change fixture verification behavior
- change the invariant sampling interval
- add workload-specific invariant policy defaults
- change the canonical default away from `enforce`
