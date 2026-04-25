# Load Workload Boundaries Design

## Goal

Refactor the load runner so workload-specific scale knobs and invariant logic live with the workload instead of the generic core, before a second workload lands and hardens the current leak.

## Scope

This design covers three changes:

1. Replace `Load::Scale#open_fraction` with a generic `extra` hash for workload-owned environment pairs.
2. Move the todos-specific invariant sampler out of `Load::Runner` and into `workloads/missing_index_todos/`.
3. Replace the runner's built-in invariant sampler construction with a workload hook.

The design keeps these boundaries unchanged:

- `Load::Runner::InvariantSample` stays in the runner with its current fields and persistence shape.
- The runner keeps breach counting, warning persistence, and abort behavior.
- `scale.rows_per_table` remains available to workload actions through `ctx[:scale]`.
- Run-record `invariant_samples` remain the same.

Out of scope:

- Polymorphic invariant sample shapes.
- Per-table scale data.
- Refactors to actions, selector, worker, reporter, oracle, dominance assertion, or fixture verifier beyond wiring needed for this seam.

## Design

### `Load::Scale`

`Load::Scale` becomes:

```ruby
Scale = Data.define(:rows_per_table, :seed, :extra) do
  def initialize(rows_per_table:, seed: 42, extra: {})
    super
  end

  def env_pairs
    extra.transform_keys { |key| key.to_s.upcase }
         .merge("ROWS_PER_TABLE" => rows_per_table.to_s)
  end
end
```

Implications:

- `rows_per_table` stays first-class so existing action code remains untouched.
- `seed` remains a scale property but never appears in `env_pairs`, because the adapter already injects `SEED`.
- Workloads own their extra environment keys without adding fixed fields to the generic type.
- Generic tests that do not care about extras stop constructing ceremonial `open_fraction: 0.0` values.

`missing-index-todos` migrates its scale to `extra: { open_fraction: 0.6 }`. The Rails demo seeds continue reading `OPEN_FRACTION`, so the live adapter path remains unchanged.

### Workload-owned invariant sampler

`Load::Workload` gains:

```ruby
def invariant_sampler(database_url:, pg:)
  nil
end
```

This hook returns either:

- `nil` for workloads with no invariant support.
- A sampler-like object responding to `#call` and returning `Load::Runner::InvariantSample`.

`workloads/missing_index_todos/invariant_sampler.rb` contains the current PG transaction logic and todos SQL. The sampler still:

- Connects through the injected `pg` client.
- Uses `SET LOCAL pg_stat_statements.track = 'none'`.
- Counts open todos and total todo rows.
- Returns `Load::Runner::InvariantSample`.

The threshold math also moves to the workload boundary. `MissingIndexTodos::Workload#invariant_sampler(database_url:, pg:)` computes:

- `open_floor = (rows_per_table * 0.3).to_i`
- `total_floor = (rows_per_table * 0.8).to_i`
- `total_ceiling = (rows_per_table * 2.0).to_i`

Those ratios stay workload-specific because they encode this workload's expected open and total drift behavior.

### Runner integration

`Load::Runner` stops defining a nested `InvariantSampler` class and deletes `default_invariant_sampler`.

Initialization becomes:

- honor an explicitly injected `invariant_sampler` first, so existing runner tests remain narrow and deterministic
- otherwise ask `@workload.invariant_sampler(database_url:, pg:)`

Continuous mode behavior:

- if the resolved sampler is `nil`, raise `Load::AdapterClient::AdapterError` with `continuous mode requires the workload to provide an invariant sampler`
- otherwise keep all existing invariant thread, warning, and breach logic untouched

This keeps the runner generic: it orchestrates sampling, but it does not know what table or ratios a workload needs.

## Test Plan

Implementation follows this TDD order:

1. Extend `load/test/scale_test.rb` to fail on the new `extra` shape and `env_pairs` contract.
2. Update `load/lib/load/scale.rb`.
3. Sweep call sites to remove `open_fraction` from generic tests and migrate the missing-index workload.
4. Add failing tests for `Load::Workload#invariant_sampler` defaulting to `nil` and for the missing-index workload returning a PG-backed sampler.
5. Move sampler coverage into `workloads/missing_index_todos/test/invariant_sampler_test.rb`.
6. Update runner construction to call the workload hook and preserve invariant-thread behavior.
7. Keep runner tests focused on orchestration by continuing to inject fake samplers there.

Validation gate before completion:

- `make test`
- 50x stability loop on the relocated invariant breach test with one `0 failures, 0 errors` line
- live finite run through `bin/load run --workload missing-index-todos ... --mode finite --duration 60` with oracle `PASS`
- `grep -r "open_fraction" load/lib load/test/runner_test.rb load/test/cli_test.rb` returns nothing
- `grep -rn "todos" load/lib/` returns nothing

## Risks And Non-Goals

- `InvariantSample` still carries todos-shaped fields. That leak is accepted for now because there is only one invariant-producing workload.
- The workload hook should stay narrow. Pushing thresholds or SQL into generic runner config would recreate the same leak in a different form.
- The change should avoid opportunistic cleanup to reduce merge friction while parallel work continues on the same branch.
