# Workload-Owned Rails Query IDs Design

## Goal

Move the missing-index todos query-id capture script out of `RailsAdapter::Commands::ResetState` while keeping Rails-specific execution mechanics inside the Rails adapter.

## Problem

`adapters/rails/lib/rails_adapter/commands/reset_state.rb` currently embeds `QUERY_IDS_SCRIPT`, keyed by `"missing-index-todos"`. That script knows about `User`, `todos`, `with_status("open")`, tenant-scoped ordering, and the normalized SQL text for the target statement family.

That makes the Rails adapter responsible for workload semantics. The adapter should know how to reset a Rails app and run a Rails script, but it should not know which query family a workload considers important.

## Boundary

Keep Rails assumptions in the Rails adapter:

- `ResetState` continues to own local vs remote reset behavior.
- `ResetState` continues to run `bin/rails db:schema:load`, seeds, `CREATE EXTENSION`, `pg_stat_statements_reset()`, and `bin/rails runner`.
- `ResetState` continues to parse query-id script stdout as JSON and return `query_ids` in the adapter response.
- `ResetState` continues to tolerate workloads that do not provide query IDs.

Move workload semantics into the workload directory:

- `missing-index-todos` owns the Rails script that warms the target query.
- `missing-index-todos` owns the normalized SQL fingerprint used to look up `pg_stat_statements.queryid`.
- The script writes `{"query_ids":[...]}` to stdout.

## File Layout

Create:

```text
workloads/missing_index_todos/rails/reset_state_query_ids.rb
```

This file is Rails-context code. It is executed by the Rails adapter via `bin/rails runner`, but it lives with the workload because it describes the workload's target statement family.

## Resolution Rule

`ResetState` resolves an optional query-id script by convention:

```text
workloads/<workload_name.tr("-", "_")>/rails/reset_state_query_ids.rb
```

For `missing-index-todos`, that resolves to:

```text
workloads/missing_index_todos/rails/reset_state_query_ids.rb
```

If `@workload` is nil or the file does not exist, `capture_query_ids` returns `nil` and reset still succeeds without `query_ids`.

## Data Flow

1. `bin/load` resolves the named workload and calls adapter `reset-state`.
2. `Load::AdapterClient#reset_state` passes `--workload <name>` to `adapters/rails/bin/bench-adapter`.
3. `RailsAdapter::Commands::ResetState` completes reset/reseed.
4. `ResetState#capture_query_ids` looks for the workload's optional Rails query-id script.
5. If present, `ResetState` reads the script and runs it with `bin/rails runner`.
6. The script warms the target query, queries `pg_stat_statements`, and writes JSON.
7. `ResetState` parses `query_ids` and includes them in its adapter result.
8. `Load::Runner` persists those IDs into `run.json` as it does today.

## Error Handling

- Missing script: not an error. Return no `query_ids`.
- Script exits non-zero: adapter reset fails with `query id capture failed: <stderr>`.
- Script outputs invalid JSON or omits `query_ids`: adapter reset fails through the existing `reset_failed` result path.
- Empty `query_ids`: allowed, but returned as an empty array. The downstream oracle may fail later if it requires non-empty query IDs.

## Testing

Adapter tests:

- Prove `ResetState` no longer has a hardcoded todos query-id constant.
- Prove `ResetState` runs a conventional workload query-id script when it exists.
- Prove `ResetState` skips query-id capture when no script exists.
- Prove query-id script failure includes stderr in the reset failure message.

Workload tests:

- Prove `workloads/missing_index_todos/rails/reset_state_query_ids.rb` contains the tenant-scoped open-todos query shape.
- Prove it writes JSON with a top-level `query_ids` key when run in Rails context. Unit coverage can lock the static script shape; live Rails behavior remains covered by the adapter integration checkpoints.

## Non-Goals

- Do not add a generic adapter-agnostic query-id hook.
- Do not pass script paths through `bin/load`.
- Do not add a second workload registry.
- Do not change the `run.json.query_ids` schema.
- Do not change reset/reseed behavior beyond moving the query-id script ownership.

## Migration

The first implementation should be behavior-preserving:

- Move the current script body exactly into the workload file.
- Replace `QUERY_IDS_SCRIPT.fetch("missing-index-todos")` test references with fixture script-path assertions.
- Keep local and remote reset command order unchanged except that the runner argument becomes the script file content instead of the in-class constant.
