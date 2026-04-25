# Load Workload Boundaries Design

## Goal

Refactor the load runner so workload-specific scale knobs and invariant logic live with the workload instead of the generic core, before a second workload lands and hardens the current leak.

## Scope

This design covers three changes:

1. Replace `Load::Scale#open_fraction` with a generic `extra` hash for workload-owned environment pairs.
2. Move the todos-specific invariant sampler out of `Load::Runner` and into `workloads/missing_index_todos/`.
3. Replace the runner's built-in invariant sampler construction with a workload hook.

The design keeps these boundaries unchanged:

- The runner keeps breach counting, warning persistence, and abort behavior.
- `scale.rows_per_table` remains available to workload actions through `ctx[:scale]`.

Out of scope:

- Per-table scale data.
- Refactors to actions, selector, worker, reporter, oracle, dominance assertion, or fixture verifier when they are expressing workload-owned todo behavior.
- Todo-specific invariant fields or threshold assumptions in generic core types are in scope and should be removed if they are touched by this seam.

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

### Generic invariant contract

`Load::Runner` keeps the invariant orchestration logic, but its value objects stop naming todos-specific fields.

The runner owns two generic types:

```ruby
InvariantCheck = Data.define(:name, :actual, :min, :max)
InvariantSample = Data.define(:checks)
```

`InvariantCheck` is pure data for one measured invariant:

- `name`: stable identifier for the metric being checked
- `actual`: measured value
- `min`: optional lower bound
- `max`: optional upper bound

`InvariantCheck` exposes generic helpers for:

- reporting breach messages
- reporting whether the check breached
- serializing itself into the run record

`InvariantSample` becomes a container of checks and exposes:

- `breaches`
- `breach?`
- `healthy?`
- `to_warning`
- `to_record(sampled_at:)`

The runner iterates checks generically when producing warnings and persisted samples. It no longer knows about `open_count`, `total_count`, or any other workload metric names.

Run-record `invariant_samples` change shape accordingly:

```json
{
  "sampled_at": "2026-04-25T15:42:48Z",
  "checks": [
    { "name": "open_count", "actual": 61234, "min": 30000, "max": null, "breach": false, "breaches": [] },
    { "name": "total_count", "actual": 101203, "min": 80000, "max": 200000, "breach": false, "breaches": [] }
  ],
  "breach": false,
  "breaches": []
}
```

Warnings follow the same generic shape:

```json
{
  "type": "invariant_breach",
  "message": "open_count 100 is below min 30000; total_count 10000 is below min 80000",
  "checks": [
    { "name": "open_count", "actual": 100, "min": 30000, "max": null, "breach": true, "breaches": ["open_count 100 is below min 30000"] },
    { "name": "total_count", "actual": 10000, "min": 80000, "max": 200000, "breach": true, "breaches": ["total_count 10000 is below min 80000"] }
  ]
}
```

This makes the runner agnostic to future workloads. A different workload can emit checks such as `products_total`, `active_merchants`, or `open_invoices` without changing runner code or persistence rules.

`workloads/missing_index_todos/invariant_sampler.rb` contains the current PG transaction logic and todos SQL. The sampler still:

- Connects through the injected `pg` client.
- Uses `SET LOCAL pg_stat_statements.track = 'none'`.
- Counts open todos and total todo rows.
- Returns `Load::Runner::InvariantSample` containing named checks.

The threshold math also moves to the workload boundary. `MissingIndexTodos::Workload#invariant_sampler(database_url:, pg:)` computes:

- `open_floor = (rows_per_table * 0.3).to_i`
- `total_floor = (rows_per_table * 0.8).to_i`
- `total_ceiling = (rows_per_table * 2.0).to_i`

Those ratios stay workload-specific because they encode this workload's expected open and total drift behavior.

The missing-index sampler returns:

```ruby
Load::Runner::InvariantSample.new(
  [
    Load::Runner::InvariantCheck.new("open_count", open_count, open_floor, nil),
    Load::Runner::InvariantCheck.new("total_count", total_count, total_floor, total_ceiling),
  ],
)
```

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
5. Add failing tests for the generic `InvariantCheck` and `InvariantSample` contract and persisted record shape.
6. Move sampler coverage into `workloads/missing_index_todos/test/invariant_sampler_test.rb`.
7. Update runner construction to call the workload hook and preserve invariant-thread behavior.
8. Keep runner tests focused on orchestration by continuing to inject fake samplers there.

Validation gate before completion:

- `make test`
- 50x stability loop on the relocated invariant breach test with one `0 failures, 0 errors` line
- live finite run through `bin/load run --workload missing-index-todos ... --mode finite --duration 60` with oracle `PASS`
- `grep -r "open_fraction" load/lib load/test/runner_test.rb load/test/cli_test.rb` returns nothing
- `grep -rn "todos" load/lib/` returns nothing

## Risks And Non-Goals

- The workload hook should stay narrow. Pushing thresholds or SQL into generic runner config would recreate the same leak in a different form.
- The change should avoid opportunistic cleanup to reduce merge friction while parallel work continues on the same branch.
