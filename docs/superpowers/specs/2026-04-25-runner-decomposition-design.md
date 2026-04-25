# Runner Decomposition Design

**Status:** Spec, ready for review
**Date:** 2026-04-25
**Builds on:** `docs/superpowers/specs/2026-04-19-load-forge-mvp-design.md`

## 1. Summary

`Load::Runner` currently owns too many responsibilities at once:

- adapter lifecycle coordination
- readiness gating
- fixture verification dispatch
- worker construction and drain
- metrics reporter lifecycle
- runtime invariant monitoring
- run-state mutation and persistence
- final outcome shaping

The class still works, but its boundaries are weak. The result is a file that is harder to reason about, harder to extend safely, and harder to review because multiple concerns are interleaved in one object.

This change keeps `Load::Runner` as the top-level use-case shell, but extracts its major subordinate responsibilities into domain-shaped collaborators:

- `RunState`
- `LoadExecution`
- `InvariantMonitor`

The public CLI and workload contracts stay unchanged.

## 2. Goals and Non-Goals

### Goals

1. Keep `Load::Runner` as the top-level object that models a single load run.
2. Remove run-state mutation and persistence logic from `Runner`.
3. Remove worker/reporter/thread lifecycle logic from `Runner`.
4. Remove invariant sampling thread and policy logic from `Runner`.
5. Preserve the current CLI, run artifact schema, and invariant-policy behavior.
6. Improve naming and boundaries so each new unit describes a domain responsibility rather than an implementation detail.

### Non-Goals

1. Change `bin/load` CLI flags or command semantics.
2. Change `run.json`, `metrics.jsonl`, or `adapter-commands.jsonl` schemas.
3. Rewrite `AdapterClient`, `ReadinessGate`, or `FixtureVerifier` in this round.
4. Introduce new runtime features or backward-compatibility shims.
5. Split `Runner` itself into separate `run` and `soak` orchestrators in this round.

## 3. Why This Exists

The current `Runner` still acts like a god object. Even after recent cleanup, it owns:

- several different classes of mutable state
- multiple concurrency mechanisms
- both domain policy and low-level thread/reporter plumbing
- both output shaping and execution coordination

That makes future work riskier than it should be. Operator-mode changes, workload-boundary changes, and invariant-policy changes all keep landing in the same file because the boundaries are too porous.

The goal of this decomposition is not abstraction for its own sake. The goal is to give each moving part one clear purpose, so future changes land in the right place.

## 4. Top-Level Shape

After this change, `Load::Runner` remains the top-level use-case object. It still owns the overall run sequence:

1. initialize collaborators
2. write initial run state
3. boot the adapter
4. wait for readiness
5. verify the fixture if a verifier is present
6. execute load with workers
7. finalize outcome
8. stop the adapter safely

What changes is that `Runner` stops owning the internal mechanics of those steps.

`Runner` should read like a coordinator. It should not still be the place where run-state hashes, warning accumulation, thread sleep flags, and worker thread drain loops all live together.

## 5. New Collaborators

### 5.1 `RunState`

`RunState` owns the in-memory run payload and the persistence contract to `Load::RunRecord`.

Responsibilities:

- build the initial `run.json` skeleton
- own the mutex that protects run-state mutation
- merge state fragments and persist them
- pin `window.start_ts` exactly once on first success
- append warnings
- append invariant samples
- record readiness payload
- record adapter metadata and query ids
- shape the final `outcome` payload from request totals and stop conditions

`RunState` is not a passive hash wrapper. It is the owner of:

- the `run.json` schema
- mutation rules
- write timing

`Runner` should stop owning:

- `@state`
- `@state_mutex`
- `@window_started`
- `initial_state`
- `write_state`
- `snapshot_state`
- warning/sample append helpers
- most of `outcome_payload`

### 5.2 `LoadExecution`

`LoadExecution` owns the active load window from “I have a workload and base URL” to “all worker-side activity is drained.”

Responsibilities:

- build workers from workload actions and scale
- construct per-worker client/selector/RNG state
- create and start the reporter
- start worker threads
- wait for the finite or continuous execution window
- drain worker threads with the current bounded shutdown behavior
- aggregate request totals from workers

Its contract back to `Runner` is narrow:

- accept an `on_first_success` callback
- return aggregate request totals when execution completes

`LoadExecution` does not own:

- adapter startup/shutdown
- fixture verification
- invariant policy
- final exit-code policy
- run-state schema knowledge beyond a metrics sink hookup

### 5.3 `InvariantMonitor`

`InvariantMonitor` owns the invariant sampling thread and breach policy.

Responsibilities:

- start and stop the monitor thread
- sleep on the configured interval
- call the workload-provided sampler
- apply `enforce|warn|off` policy
- track consecutive breaches
- trigger stop on invariant breach when policy requires it
- surface monitor failures cleanly

Its inputs are:

- sampler
- policy
- interval
- stop flag
- callbacks for sample recording, warning recording, and stop triggering

Its outputs are:

- emitted samples
- emitted warnings
- stop trigger on policy breach
- failure surfaced to `Runner`

It must not know the `run.json` schema directly. Policy enforcement belongs here, but state-persistence structure belongs in `RunState`.

## 6. Existing Collaborators That Stay Put

These units stay where they are in this round:

- `Load::ReadinessGate`
- `Load::FixtureVerifier`
- `Load::AdapterClient`

That is intentional. The biggest boundary problems are inside `Runner`, not at those seams.

There is a plausible future `AdapterSession` extraction, but it is not necessary for this round and would widen the blast radius without enough immediate payoff.

## 7. Interaction Model

The intended interaction is:

- `Runner` constructs `RunState`
- `Runner` constructs `LoadExecution`
- `Runner` constructs `InvariantMonitor` when mode and policy require it
- `Runner` wires small callbacks between them

Important callback examples:

- `LoadExecution` calls `RunState#pin_window_start(now:)` on first success
- `InvariantMonitor` calls `RunState#append_invariant_sample(...)`
- `InvariantMonitor` calls `RunState#append_warning(...)`
- `InvariantMonitor` triggers the shared stop flag on enforced breach

This keeps collaborator APIs narrow without passing the whole `Runner` into every helper object.

## 8. Naming

Naming should follow domain responsibilities, not implementation details.

Chosen names:

- `RunState`
- `LoadExecution`
- `InvariantMonitor`

Rejected names:

- `WorkerGroup`
- `WorkerSupervisor`
- `WorkerManager`
- `BootstrapPhase`
- `LoadPhase`
- `ShutdownPhase`

The rejected names are either too implementation-shaped or too procedural. The chosen names describe what each unit is responsible for in the domain of running load.

## 9. Sequencing

Implementation should happen in this order:

1. extract `RunState`
2. extract `InvariantMonitor`
3. extract `LoadExecution`

Why this order:

- `RunState` is the most self-contained seam and removes the most mutable noise from `Runner`
- `InvariantMonitor` becomes easier to extract once warning/sample persistence has a clear owner
- `LoadExecution` is the riskiest of the three because it touches worker construction, reporting, and drain behavior, so it should come last

## 10. Behavioral Constraints

This refactor must preserve:

- current `bin/load` behavior
- current invariant-policy behavior
- current run artifact schema
- current readiness behavior
- current worker shutdown semantics
- current stop failure semantics
- current verifier timing: after readiness, before workers

No intentional product behavior changes are part of this work.

## 11. Verification Requirements

The refactor is complete only if the existing suites stay green without semantic drift:

- `load/test/*`
- `workloads/missing_index_todos/test/*`
- `adapters/rails/test/*`

Particular regression attention points:

- first-success pinning of `window.start_ts`
- `warn` vs `enforce` invariant behavior
- `off` invariant policy
- no-successful-requests outcome
- adapter stop error handling
- continuous-mode shutdown timing
- worker request-total aggregation

## 12. Risks

### 12.1 `RunState`

Main risk:

- accidentally changing write timing or final payload shape

Mitigation:

- keep the existing tests as behavioral locks
- move schema shaping without rewriting the schema itself

### 12.2 `InvariantMonitor`

Main risk:

- subtle drift in `enforce|warn|off` semantics

Mitigation:

- preserve current runner tests unchanged wherever possible
- only move the loop and policy branch, not the behavior

### 12.3 `LoadExecution`

Main risk:

- races around first success, reporter lifecycle, or drain behavior

Mitigation:

- keep the worker/reporter/drain tests green unchanged
- avoid changing the client, selector, or rate-limiter contracts as part of this extraction

## 13. Success Criteria

This design succeeds when:

1. `Runner` reads as a high-level coordinator instead of a multi-purpose implementation file.
2. `RunState`, `LoadExecution`, and `InvariantMonitor` each have one clear job.
3. Existing operator behavior and artifact shapes do not change.
4. The next runner-adjacent change can land in one of those collaborators instead of re-expanding `Runner`.
