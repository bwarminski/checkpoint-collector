# Mixed Missing-Index Fixture Walkthrough

*2026-04-25T19:10:10Z by Showboat 0.6.1*
<!-- showboat-id: 43a98a21-46e2-4df1-aa8b-a8962738c56d -->

This walkthrough follows the current mixed missing-index branch in execution order. It starts with the design anchors, then traces the CLI entrypoint, workload lookup, runner lifecycle, runtime invariant policy, workload-owned invariant sampling, fixture verification, Rails adapter handoff, and the mixed workload/oracle pair that make the agent exercise work.

The current branch has two important layers on top of the original mixed-fixture spec: workload-owned scale and invariant boundaries, and operator-selectable invariant policies. Reading those first makes the code easier to follow.

```bash
sed -n '1,120p' docs/superpowers/specs/2026-04-24-mixed-missing-index-design.md && printf '\n---\n' && sed -n '1,120p' docs/superpowers/specs/2026-04-25-invariant-policy-design.md && printf '\n---\n' && sed -n '1,120p' docs/superpowers/specs/2026-04-25-load-workload-boundaries-design.md
```

````output
# Mixed Missing-Index Todo Fixture — Design Spec

**Status:** Spec, ready for review
**Date:** 2026-04-24
**Builds on:** `docs/superpowers/specs/2026-04-19-load-forge-mvp-design.md`

## 1. Overview

The current `missing-index-todos` fixture is too narrow for the agent exercise Brett wants to run. It reliably reproduces one pathology, but the traffic shape is unrealistically clean: one dominant endpoint, one dominant query family, and very little background noise.

This change keeps the fixture name and the primary oracle contract, but replaces the underlying app and workload behavior with a richer TodoMVC-shaped JSON API and a mixed traffic pattern. The new fixture still leaves the missing `todos.status` index as the primary pathology, but it also preserves other classic app/database problems that an autonomous agent may notice while diagnosing the system:

- missing index on `todos.status` for the dominant "list open todos" path
- count-side N+1 behavior
- one text-search/query-shape pathology corresponding to the earlier `oracle/rewrite-like` fix family

The result should feel like a small realistic app under mixed traffic, not a single-purpose benchmark endpoint.

## 2. Goals and Non-Goals

### Goals

1. Preserve the current fixture identity: the workload stays named `missing-index-todos`.
2. Keep the primary oracle focused on the missing-index pathology only.
3. Replace the single-action workload with a mixed-action workload that still makes the missing-index path dominant.
4. Support both finite benchmark runs and long-running background traffic for live diagnosis sessions.
5. Keep the app-under-test in `~/db-specialist-demo` and evolve it into a fixture-friendly TodoMVC-style JSON service rather than introducing a second demo app.
6. Preserve as much of the current pathology surface as is practical, including the count-side N+1 and the older text-search/query-shape issue.

### Non-Goals

1. Introduce a second formal oracle for the N+1 or text-search issues in this round.
2. Rebrand the workload or rename the fixture. The existing `missing-index-todos` name stays in place for continuity.
3. Rewrite merged history to make the app evolution look more organic.
4. Turn the benchmark app into a full frontend TodoMVC implementation. The fixture app is JSON API only.

## 3. Why This Exists

The agent exercise Brett wants to run starts with `checkpoint-collector`, a live Postgres, and a live app, but without direct access to the demo app repo. That means the exercise only works if the observable system has both:

- a dominant diagnosable signal that points to the real problem
- enough legitimate background traffic that diagnosis requires judgment rather than one obvious bad endpoint

The current fixture only satisfies the first condition. This design adds the second without losing the first.

## 4. System Shape

The fixture continues to span two repos:

- `~/checkpoint-collector`
  - owns the workload definition, runner/oracle behavior, docs, and verification flow
- `~/db-specialist-demo`
  - remains the app-under-test and gains the richer Todo JSON API surface

The benchmark still runs against normal app HTTP routes and normal database tables. The collector still observes the system through `pg_stat_statements` and ClickHouse. No benchmark-only observability path is added.

## 5. App-Under-Test Design

`~/db-specialist-demo` becomes a small TodoMVC-shaped JSON API over the existing `users` and `todos` tables.

### 5.1 Data model

The schema remains intentionally simple:

- `users`
- `todos`
  - `user_id`
  - `status`
  - title/content fields as needed by the existing app shape

The broken schema characteristic remains explicit:

- index on `todos.user_id`
- **no index on `todos.status`**

This omission is intentional and remains the primary oracle target.

### 5.2 JSON routes

The app exposes these routes:

- `GET /api/todos`
  - query params:
    - `status=open|closed|all`
    - `page`
    - `per_page`
    - `order=created_desc`
  - default ordering is newest-first
  - `status=open` is the canonical missing-index read path

- `POST /api/todos`
  - creates one todo for a chosen user

- `PATCH /api/todos/:id`
  - updates a todo, primarily used to mark open todos closed

- `DELETE /api/todos/completed`
  - bulk-deletes completed/non-open todos
  - bounded per call; see §5.2.1

- `GET /api/todos/counts`
  - returns counts in a way that preserves the count-side N+1 pathology

- `GET /api/todos/search`
  - preserves the old text-search/query-shape pathology associated with the earlier `rewrite_like` fix family

### 5.2.1 Bulk delete must be bounded

The `DELETE /api/todos/completed` endpoint must be bounded per call. Acceptable shapes:

- **per-user scope:** `DELETE FROM todos WHERE user_id = $1 AND status != 'open'` — deletes one user's completed rows; mean batch size ≈ `total_completed / users` and auto-stabilizes (more closed rows produce larger batches).
- **explicit LIMIT:** delete a fixed N (e.g., 50) of the oldest completed rows per call.

Unbounded `DELETE FROM todos WHERE status != 'open'` is forbidden. A single such call collapses the closed pool and breaks the §6.2 `total_count` invariant for the remainder of the run. The constraint is load-bearing: a future "cleanup" PR that reaches for `Todo.where.not(status: 'open').destroy_all` silently destroys the soak-mode contract.

### 5.3 Pathology preservation

The new API should preserve three issue classes; each has an explicit protection contract:

1. **Missing index** (primary, oracle-backed)

---
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

`off` does not disable workload-local fixture verification. For
`missing-index-todos`, `run` and `soak` still execute the pre-flight verifier
before workers start, so those commands still require whatever verifier inputs
the workload needs, including `DATABASE_URL`.

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


---
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
    reserved = %i[seed rows_per_table SEED ROWS_PER_TABLE]
    bad = extra.keys.find { |key| reserved.include?(key.to_sym) }
    raise ArgumentError, "extra cannot contain reserved key: #{bad}" if bad

    super
  end

  def env_pairs
    { "ROWS_PER_TABLE" => rows_per_table.to_s }
      .merge(extra.transform_keys { |key| key.to_s.upcase })
  end
end
```

Implications:

- `rows_per_table` stays first-class so existing action code remains untouched.
- `seed` remains a scale property but never appears in `env_pairs`, because the adapter already injects `SEED`.
- `extra` rejects reserved keys for `seed` and `rows_per_table` so workload-specific env knobs cannot override canonical values.
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
````

```bash
sed -n '1,200p' load/lib/load/scale.rb && printf '\n---\n' && sed -n '1,200p' load/lib/load/workload.rb && printf '\n---\n' && sed -n '1,200p' workloads/missing_index_todos/workload.rb && printf '\n---\n' && sed -n '1,200p' workloads/missing_index_todos/invariant_sampler.rb
```

```output
# ABOUTME: Describes the scale parameters for a workload.
# ABOUTME: Exposes environment variable pairs for workload extras.
module Load
  Scale = Data.define(:rows_per_table, :seed, :extra) do
    def initialize(rows_per_table:, seed: 42, extra: {})
      reserved = %w[seed rows_per_table]
      bad = extra.keys.find { |key| reserved.include?(key.to_s.downcase) }
      raise ArgumentError, "extra cannot contain reserved key: #{bad}" if bad
      normalized = extra.keys.group_by { |key| key.to_s.upcase }
      duplicate = normalized.find { |_, keys| keys.length > 1 }&.first
      raise ArgumentError, "extra cannot contain duplicate key after normalization: #{duplicate}" if duplicate

      super
    end

    def env_pairs
      { "ROWS_PER_TABLE" => rows_per_table.to_s }
        .merge(extra.transform_keys { |key| key.to_s.upcase })
    end
  end
end

---
# ABOUTME: Declares the base class for a runnable workload.
# ABOUTME: Concrete workloads provide the name, scale, actions, and plan.
module Load
  class Workload
    def name
      raise NotImplementedError
    end

    def scale
      raise NotImplementedError
    end

    def actions
      raise NotImplementedError
    end

    def load_plan
      raise NotImplementedError
    end

    def invariant_sampler(database_url:, pg:)
      nil
    end
  end
end

---
# ABOUTME: Defines the missing-index workload used for the todos benchmark path.
# ABOUTME: Declares the fixed scale, weighted actions, and load plan for the run.
require_relative "../../load/lib/load"
require_relative "invariant_sampler"
require_relative "actions/close_todo"
require_relative "actions/create_todo"
require_relative "actions/delete_completed_todos"
require_relative "actions/fetch_counts"
require_relative "actions/list_open_todos"
require_relative "actions/list_recent_todos"
require_relative "actions/search_todos"

module Load
  module Workloads
    module MissingIndexTodos
      class Workload < Load::Workload
        def name
          "missing-index-todos"
        end

        def scale
          Load::Scale.new(rows_per_table: 100_000, extra: { open_fraction: 0.6 }, seed: 42)
        end

        def actions
          [
            Load::ActionEntry.new(Actions::ListOpenTodos, 68),
            Load::ActionEntry.new(Actions::ListRecentTodos, 12),
            Load::ActionEntry.new(Actions::CreateTodo, 7),
            Load::ActionEntry.new(Actions::CloseTodo, 7),
            Load::ActionEntry.new(Actions::DeleteCompletedTodos, 3),
            Load::ActionEntry.new(Actions::FetchCounts, 2),
            Load::ActionEntry.new(Actions::SearchTodos, 3),
          ]
        end

        def load_plan
          Load::LoadPlan.new(workers: 16, duration_seconds: 60, rate_limit: :unlimited, seed: nil)
        end

        def invariant_sampler(database_url:, pg:)
          rows_per_table = scale.rows_per_table
          Load::Workloads::MissingIndexTodos::InvariantSampler.new(
            pg:,
            database_url:,
            open_floor: (rows_per_table * 0.3).to_i,
            total_floor: (rows_per_table * 0.8).to_i,
            total_ceiling: (rows_per_table * 2.0).to_i,
          )
        end
      end
    end
  end
end

Load::WorkloadRegistry.register("missing-index-todos", Load::Workloads::MissingIndexTodos::Workload)

---
# ABOUTME: Samples missing-index todo table invariants using an isolated PG connection.
# ABOUTME: Returns named invariant checks for open and total todo counts.
require_relative "../../load/lib/load"

module Load
  module Workloads
    module MissingIndexTodos
      class InvariantSampler
        OPEN_COUNT_SQL = "SELECT COUNT(*) AS count FROM todos WHERE status = 'open'".freeze
        TOTAL_COUNT_SQL = "SELECT reltuples::bigint AS count FROM pg_class WHERE relname = 'todos'".freeze

        def initialize(pg:, database_url:, open_floor:, total_floor:, total_ceiling:)
          @pg = pg
          @database_url = database_url
          @open_floor = open_floor
          @total_floor = total_floor
          @total_ceiling = total_ceiling
        end

        def call
          with_connection do |connection|
            connection.transaction do |txn|
              txn.exec("SET LOCAL pg_stat_statements.track = 'none'")
              open_count = txn.exec(OPEN_COUNT_SQL).first.fetch("count").to_i
              total_count = txn.exec(TOTAL_COUNT_SQL).first.fetch("count").to_i
              Load::Runner::InvariantSample.new(
                [
                  Load::Runner::InvariantCheck.new("open_count", open_count, @open_floor, nil),
                  Load::Runner::InvariantCheck.new("total_count", total_count, @total_floor, @total_ceiling),
                ],
              )
            end
          end
        end

        private

        def with_connection
          connection = @pg.connect(@database_url)
          yield connection
        ensure
          connection&.close
        end
      end
    end
  end
end
```

```bash
sed -n '1,200p' bin/load && printf '\n---\n' && sed -n '1,280p' load/lib/load/cli.rb
```

```output
#!/usr/bin/env ruby
# ABOUTME: Runs the load runner CLI for benchmark workloads.
# ABOUTME: Installs signal traps and delegates command handling to Load::CLI.
VERSION_PATH = File.expand_path("../VERSION", __dir__)

require_relative "../load/lib/load"

stop_flag = Load::Runner::InternalStopFlag.new
previous_handlers = {
  "INT" => Signal.trap("INT") { stop_flag.trigger(:sigint) },
  "TERM" => Signal.trap("TERM") { stop_flag.trigger(:sigterm) },
}
begin
  exit Load::CLI.new(
    argv: ARGV,
    version: File.read(VERSION_PATH).strip,
    stop_flag:,
    stdout: $stdout,
    stderr: $stderr,
  ).run
ensure
  previous_handlers.each do |signal, handler|
    Signal.trap(signal, handler)
  end
end

---
# ABOUTME: Parses the load runner CLI and resolves named workloads.
# ABOUTME: Keeps command handling separate from runner orchestration.
require "optparse"
require "net/http"
require "tmpdir"

module Load
  class CLI
    VerifierError = Class.new(StandardError)
    USAGE = <<~USAGE.freeze
      Usage: bin/load run|soak --workload NAME --adapter PATH --app-root PATH [--readiness-path /up|none] [--startup-grace-seconds 15] [--metrics-interval-seconds 5] [--invariants enforce|warn|off]
             bin/load verify-fixture --workload NAME --adapter PATH --app-root PATH
    USAGE

    def initialize(argv:, version:, runner_factory: nil, verifier_factory: nil, stop_flag: nil, stdout: $stdout, stderr: $stderr)
      @argv = argv.dup
      @version = version
      @verifier_factory = verifier_factory || default_verifier_factory
      @runner_factory = runner_factory || default_runner_factory
      @stop_flag = stop_flag || Load::Runner::InternalStopFlag.new
      @stdout = stdout
      @stderr = stderr
    end

    def run
      command = @argv.shift

      case command
      when "run"
        run_command(mode: :finite)
      when "soak"
        run_command(mode: :continuous)
      when "verify-fixture"
        verify_fixture_command
      when "--help", "-h", nil
        @stdout.puts(USAGE)
        Load::ExitCodes::SUCCESS
      when "--version", "-v"
        @stdout.puts(@version)
        Load::ExitCodes::SUCCESS
      else
        @stderr.puts("unknown command: #{command}")
        usage_error
      end
    rescue Load::FixtureVerifier::VerificationError => error
      @stderr.puts(error.message)
      Load::ExitCodes::ADAPTER_ERROR
    rescue VerifierError, Load::AdapterClient::AdapterError, Load::ReadinessGate::Timeout => error
      @stderr.puts(error.message)
      Load::ExitCodes::ADAPTER_ERROR
    rescue OptionParser::ParseError, ArgumentError => error
      @stderr.puts(error.message)
      usage_error
    rescue StandardError => error
      @stderr.puts(error.message)
      Load::ExitCodes::USAGE_ERROR
    end

    private

    def run_command(mode:)
      options = parse_run_options
      workload = load_workload(options.fetch(:workload))
      runner = @runner_factory.call(
        workload: workload,
        mode: mode,
        adapter_bin: options.fetch(:adapter_bin),
        app_root: options.fetch(:app_root),
        runs_dir: options.fetch(:runs_dir),
        readiness_path: options.fetch(:readiness_path),
        startup_grace_seconds: options.fetch(:startup_grace_seconds),
        metrics_interval_seconds: options.fetch(:metrics_interval_seconds),
        invariant_policy: options.fetch(:invariant_policy),
        stop_flag: @stop_flag,
        stdout: @stdout,
        stderr: @stderr,
      )
      runner.run
    end

    def verify_fixture_command
      options = parse_shared_options
      workload = load_workload(options.fetch(:workload))
      verifier = build_verifier(
        workload_name: options.fetch(:workload),
        adapter_bin: options.fetch(:adapter_bin),
        app_root: options.fetch(:app_root),
        stdout: @stdout,
        stderr: @stderr,
      )
      raise ArgumentError, "unknown workload: #{options.fetch(:workload)}" unless verifier

      verify_fixture(workload:, verifier:, options:)
    end

    def default_runner_factory
      lambda do |workload:, adapter_bin:, app_root:, runs_dir:, readiness_path:, startup_grace_seconds:, metrics_interval_seconds:, invariant_policy:, stop_flag:, stdout:, stderr:, mode:|
        run_dir = File.join(runs_dir, "#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}-#{workload.name}")
        run_record = Load::RunRecord.new(run_dir:)
        adapter_client = Load::AdapterClient.new(adapter_bin:, run_record:)
        verifier = nil
        if fixture_verification_required?(workload_name: workload.name, mode:)
          verifier = build_verifier(
            workload_name: workload.name,
            adapter_bin:,
            app_root:,
            stdout:,
            stderr:,
          )
        end
        Load::Runner.new(
          workload:,
          adapter_client:,
          run_record:,
          clock: -> { Time.now.utc },
          sleeper: ->(seconds) { sleep(seconds) },
          readiness_path:,
          startup_grace_seconds:,
          metrics_interval_seconds:,
          workload_file: workload_path(workload.name),
          app_root:,
          adapter_bin:,
          stop_flag:,
          verifier:,
          mode:,
          invariant_policy:,
          stderr:,
        )
      end
    end

    def default_verifier_factory
      lambda do |workload_name:, adapter_bin:, app_root:, stdout:, stderr:|
        next unless workload_name == "missing-index-todos"

        Load::FixtureVerifier.new(
          workload_name:,
          adapter_bin:,
          app_root:,
          stdout:,
          stderr:,
          database_url: ENV["DATABASE_URL"],
          pg: PG,
        )
      end
    end

    def build_verifier(workload_name:, adapter_bin:, app_root:, stdout:, stderr:)
      @verifier_factory.call(
        workload_name:,
        adapter_bin:,
        app_root:,
        stdout:,
        stderr:,
      )
    rescue Load::FixtureVerifier::VerificationError
      raise
    rescue StandardError => error
      raise VerifierError, error.message
    end

    def verify_fixture(workload:, verifier:, options:)
      adapter_client = nil
      pid = nil
      failure = nil
      adapter_client = Load::AdapterClient.new(adapter_bin: options.fetch(:adapter_bin))
      adapter_client.describe
      adapter_client.prepare(app_root: options.fetch(:app_root))
      adapter_client.reset_state(app_root: options.fetch(:app_root), workload: workload.name, scale: workload.scale)
      start_response = adapter_client.start(app_root: options.fetch(:app_root))
      base_url = start_response.fetch("base_url")
      pid = start_response.fetch("pid")
      Load::ReadinessGate.new(
        base_url:,
        readiness_path: "/up",
        startup_grace_seconds: 15.0,
        clock: -> { Time.now.utc },
        sleeper: ->(seconds) { sleep(seconds) },
        http: Net::HTTP,
      ).call
      verifier.call(base_url:)
      Load::ExitCodes::SUCCESS
    rescue Load::FixtureVerifier::VerificationError => error
      failure = error
      raise
    rescue StandardError => error
      failure = error
      raise VerifierError, error.message
    ensure
      begin
        adapter_client&.stop(pid:) if pid
      rescue StandardError
        raise unless failure
      end
    end

    def parse_shared_options
      options = {
      }

      parser = OptionParser.new do |parser|
        parser.on("--workload NAME") { |value| options[:workload] = value }
        parser.on("--adapter PATH") { |value| options[:adapter_bin] = value }
        parser.on("--app-root PATH") { |value| options[:app_root] = value }
      end
      parser.parse!(@argv)

      raise OptionParser::ParseError, "missing --workload" unless options[:workload]
      raise OptionParser::ParseError, "missing --adapter" unless options[:adapter_bin]
      raise OptionParser::ParseError, "missing --app-root" unless options[:app_root]

      options
    end

    def parse_run_options
      options = {
        runs_dir: "runs",
        readiness_path: "/up",
        startup_grace_seconds: 15.0,
        metrics_interval_seconds: 5.0,
        invariant_policy: :enforce,
      }

      parser = OptionParser.new do |parser|
        parser.on("--workload NAME") { |value| options[:workload] = value }
        parser.on("--adapter PATH") { |value| options[:adapter_bin] = value }
        parser.on("--app-root PATH") { |value| options[:app_root] = value }
        parser.on("--runs-dir DIR") { |value| options[:runs_dir] = value }
        parser.on("--readiness-path PATH") { |value| options[:readiness_path] = value == "none" ? nil : value }
        parser.on("--startup-grace-seconds N", Float) { |value| options[:startup_grace_seconds] = value }
        parser.on("--metrics-interval-seconds N", Float) { |value| options[:metrics_interval_seconds] = value }
        parser.on("--invariants POLICY") { |value| options[:invariant_policy] = parse_invariant_policy(value) }
      end
      parser.parse!(@argv)

      raise OptionParser::ParseError, "missing --workload" unless options[:workload]
      raise OptionParser::ParseError, "missing --adapter" unless options[:adapter_bin]
      raise OptionParser::ParseError, "missing --app-root" unless options[:app_root]

      options
    end

    def parse_invariant_policy(value)
      policy = value.to_sym
      return policy if %i[enforce warn off].include?(policy)

      raise OptionParser::ParseError, "invalid option: --invariants #{value}"
    end

    def load_workload(name)
      Load::WorkloadRegistry.fetch(name).new
    rescue Load::WorkloadRegistry::Error
      begin
        require workload_path(name)
      rescue LoadError
        raise ArgumentError, "unknown workload: #{name}"
      end
      Load::WorkloadRegistry.fetch(name).new
    rescue Load::WorkloadRegistry::Error
      raise ArgumentError, "unknown workload: #{name}"
    end

    def usage_error
      @stderr.puts(USAGE)
      Load::ExitCodes::USAGE_ERROR
    end

    def fixture_verification_required?(workload_name:, mode:)
      workload_name == "missing-index-todos" && %i[finite continuous].include?(mode)
    end

    def workload_path(name)
      File.expand_path("../../../workloads/#{name.tr("-", "_")}/workload", __dir__)
    end
  end
end
```

The first important branch change is that workload-specific env knobs and invariant construction no longer live in the generic core.  now carries generic  env pairs,  can supply its own invariant sampler, and  owns the todo-specific thresholds and SQL.

At the top of execution, Usage: bin/load run|soak --workload NAME --adapter PATH --app-root PATH [--readiness-path /up|none] [--startup-grace-seconds 15] [--metrics-interval-seconds 5] [--invariants enforce|warn|off]
       bin/load verify-fixture --workload NAME --adapter PATH --app-root PATH stays thin. It installs the signal traps, reads the version file, and hands the real command semantics to . The CLI is also where the named workload lookup and invariant-policy parsing now happen.

The runner is still the execution hub. It owns the adapter lifecycle, readiness probe, worker construction, metrics reporting, and runtime invariant policy. The merged branch moved two responsibilities out of the runner compared to the earlier branch state: scale and invariant sampler definition now belong to the workload, and the runner only asks the workload for those domain-specific pieces.

```bash
sed -n '1,260p' load/lib/load/runner.rb && printf '\n---\n' && sed -n '261,520p' load/lib/load/runner.rb
```

```output
# ABOUTME: Orchestrates adapter lifecycle, readiness probing, and worker execution.
# ABOUTME: Writes run state as workers report the first successful response.
require "net/http"
require "pg"
require "thread"
require "time"

module Load
  class Runner
    WORKER_DRAIN_TIMEOUT_SECONDS = 1.0
    CONTINUOUS_POLL_SECONDS = 0.1
    DEFAULT_INVARIANT_SAMPLE_INTERVAL_SECONDS = 60.0
    Runtime = Data.define(:clock, :sleeper, :http, :stop_flag)
    Settings = Data.define(:readiness_path, :startup_grace_seconds, :metrics_interval_seconds, :workload_file, :app_root, :adapter_bin)

    MetricsSink = Data.define(:run_record) do
      def <<(line)
        run_record.append_metrics(line)
      end
    end

    class TrackingBuffer < Load::Metrics::Buffer
      def initialize(runner)
        super()
        @runner = runner
        @started = false
        @request_totals = { total: 0, ok: 0, error: 0 }
        @runner.send(:register_tracking_buffer, self)
      end

      def record_ok(**kwargs)
        super(**kwargs)
        @request_totals[:total] += 1
        @request_totals[:ok] += 1
        return if @started

        @started = true
        @runner.pin_window_start
      end

      def record_error(**kwargs)
        super(**kwargs)
        @request_totals[:total] += 1
        @request_totals[:error] += 1
      end

      def request_totals
        @request_totals.dup
      end
    end

    InvariantCheck = Data.define(:name, :actual, :min, :max) do
      def breaches
        [].tap do |messages|
          messages << "#{name} #{actual} is below min #{min}" if !min.nil? && actual < min
          messages << "#{name} #{actual} is above max #{max}" if !max.nil? && actual > max
        end
      end

      def breach?
        !breaches.empty?
      end

      def to_record
        { name:, actual:, min:, max:, breach: breach?, breaches: }
      end
    end

    InvariantSample = Data.define(:checks) do
      def breaches
        checks.flat_map(&:breaches)
      end

      def breach?
        !breaches.empty?
      end

      def healthy?
        !breach?
      end

      def to_warning
        { type: "invariant_breach", message: breaches.join("; "), checks: checks.map(&:to_record) }
      end

      def to_record(sampled_at:)
        { sampled_at:, checks: checks.map(&:to_record), breach: breach?, breaches: }
      end
    end

    class InvariantSamplerFailure < StandardError; end
    class InvariantSamplerShutdown < StandardError; end

    def initialize(workload:, adapter_client:, run_record:, clock:, sleeper:, http: Net::HTTP, readiness_path: "/up", startup_grace_seconds: 15, metrics_interval_seconds: 5, workload_file: nil, app_root: nil, adapter_bin: nil, stop_flag: nil, verifier: nil, mode: :finite, invariant_policy: :enforce, invariant_sampler: nil, invariant_sample_interval_seconds: DEFAULT_INVARIANT_SAMPLE_INTERVAL_SECONDS, database_url: ENV["DATABASE_URL"], pg: PG, stderr: $stderr)
      @workload = workload
      @adapter_client = adapter_client
      @run_record = run_record
      @runtime = Runtime.new(clock, sleeper, http, stop_flag || InternalStopFlag.new)
      @settings = Settings.new(readiness_path, startup_grace_seconds, metrics_interval_seconds, workload_file, app_root, adapter_bin)
      @verifier = verifier
      @mode = mode
      @stderr = stderr
      @invariant_policy = invariant_policy
      @invariant_sampler = if @invariant_policy == :off
        invariant_sampler
      else
        invariant_sampler || @workload.invariant_sampler(database_url:, pg:)
      end
      if @mode == :continuous && @invariant_policy != :off && @invariant_sampler.nil?
        raise AdapterClient::AdapterError, "continuous mode requires the workload to provide an invariant sampler"
      end
      @invariant_sample_interval_seconds = invariant_sample_interval_seconds
      @state_mutex = Mutex.new
      @tracking_buffers = []
      @state = initial_state
      @window_started = false
      @consecutive_invariant_breaches = 0
      @invariant_thread_sleeping = false
      @invariant_failure = nil
    end

    def run
      begin
        @run_record.write_run(snapshot_state)
        adapter_describe = @adapter_client.describe
        validate_adapter_response!(adapter_describe, %w[name framework runtime], "describe")
        write_state(adapter: {
          describe: adapter_describe,
          bin: @settings.adapter_bin || @adapter_client.adapter_bin,
          app_root: @settings.app_root,
        })

        @adapter_client.prepare(app_root: @settings.app_root)
        reset_state = @adapter_client.reset_state(app_root: @settings.app_root, workload: @workload.name, scale: @workload.scale)
        write_state(query_ids: Array(reset_state["query_ids"]).map(&:to_s)) if reset_state.is_a?(Hash) && reset_state["query_ids"]

        start_response = @adapter_client.start(app_root: @settings.app_root)
        validate_adapter_response!(start_response, %w[pid base_url], "start")
        write_state(adapter: { pid: start_response.fetch("pid"), base_url: start_response.fetch("base_url") })

        probe_readiness(start_response.fetch("base_url"))
        verify_fixture(base_url: start_response.fetch("base_url"))
        start_workers(start_response.fetch("base_url"))

        result = finish_run
      rescue InvariantSamplerFailure
        write_state(outcome: outcome_payload(aborted: true, error_code: "invariant_sampler_failed"))
        result = Load::ExitCodes::ADAPTER_ERROR
      rescue Load::FixtureVerifier::VerificationError => error
        write_state(outcome: outcome_payload(aborted: true, error_code: "fixture_verification_failed").merge(error_message: error.message))
        result = Load::ExitCodes::ADAPTER_ERROR
      rescue AdapterClient::AdapterError
        write_state(outcome: outcome_payload(aborted: true, error_code: "adapter_error"))
        result = Load::ExitCodes::ADAPTER_ERROR
      rescue Load::ReadinessGate::Timeout
        write_state(outcome: outcome_payload(aborted: true, error_code: "readiness_timeout"))
        result = Load::ExitCodes::ADAPTER_ERROR
      ensure
        result = stop_adapter_safely(result)
      end

      result
    end

    private

    def verify_fixture(base_url:)
      return unless @verifier

      @verifier.call(base_url:)
    end

    def probe_readiness(base_url)
      write_state(
        window: {
          readiness: Load::ReadinessGate.new(
            base_url:,
            readiness_path: @settings.readiness_path,
            startup_grace_seconds: @settings.startup_grace_seconds,
            clock: @runtime.clock,
            sleeper: @runtime.sleeper,
            http: @runtime.http,
          ).call,
        },
      )
    end

    def start_workers(base_url)
      plan = @workload.load_plan
      rate_limiter = Load::RateLimiter.new(rate_limit: plan.rate_limit, clock: @runtime.clock, sleeper: @runtime.sleeper)
      entries = @workload.actions
      seed = plan.seed.nil? ? @workload.scale.seed : plan.seed
      threads = []
      invariant_thread = nil

      workers = Array.new(plan.workers) do |index|
        Load::Worker.new(
          worker_id: index + 1,
          selector: Load::Selector.new(entries: entries, rng: Random.new(seed + index)),
          buffer: tracking_buffer,
          client: Load::Client.new(base_url: base_url, http: @runtime.http),
          ctx: { base_url: base_url, scale: @workload.scale },
          rng: Random.new(seed + index),
          rate_limiter: rate_limiter,
          stop_flag: @runtime.stop_flag,
        )
      end

      reporter = Load::Reporter.new(
        workers:,
        interval_seconds: @settings.metrics_interval_seconds,
        sink: MetricsSink.new(@run_record),
        clock: @runtime.clock,
        sleeper: @runtime.sleeper,
      )
      reporter.start
      threads = workers.map { |worker| Thread.new { worker.run } }
      invariant_thread = start_invariant_thread
      execute_window(plan.duration_seconds)
    ensure
      stop_invariant_thread(invariant_thread)
      drain_workers(threads)
      reporter.stop
      raise_invariant_failure_if_present
    end

    def execute_window(duration_seconds)
      if @mode == :continuous
        wait_for_stop_signal
      else
        wait_for_window_end(duration_seconds)
      end
    end

    def wait_for_window_end(duration_seconds)
      deadline = current_time + duration_seconds

      until @runtime.stop_flag.call
        remaining = deadline - current_time
        if remaining <= 0
          @runtime.stop_flag.trigger(:timeout) if @runtime.stop_flag.respond_to?(:trigger)
          break
        end

        Thread.pass
        next if @runtime.stop_flag.call

        remaining = deadline - current_time
        next if remaining <= 0

        @runtime.sleeper.call([1.0, remaining].min)
      end
    end

    def wait_for_stop_signal
      until @runtime.stop_flag.call
        Thread.pass
        @runtime.sleeper.call(CONTINUOUS_POLL_SECONDS)
      end
    end

---

    def start_invariant_thread
      return unless @mode == :continuous
      return if @invariant_policy == :off
      return unless @invariant_sampler

      Thread.new do
        begin
          loop do
            break if @runtime.stop_flag.call

            begin
              Thread.handle_interrupt(InvariantSamplerShutdown => :immediate) do
                mark_invariant_thread_sleeping(true)
                @runtime.sleeper.call(@invariant_sample_interval_seconds)
              end
            rescue StopIteration, InvariantSamplerShutdown
              break
            ensure
              mark_invariant_thread_sleeping(false)
            end

            break if @runtime.stop_flag.call

            Thread.handle_interrupt(InvariantSamplerShutdown => :never) do
              sample_invariants
            end
          end
        rescue StopIteration, InvariantSamplerShutdown
          nil
        rescue StandardError => error
          record_invariant_failure(error)
          trigger_stop(:invariant_sampler_failed)
        end
      end
    end

    # sample -> breach? -> enforce -> ++counter -> >=3? -> trigger_stop
    #                 -> warn    -> @stderr.puts (no counter)
    #                 -> off     -> unreachable (thread never started)
    #      -> !breach  -> counter = 0 (enforce only; harmless elsewhere)
    def sample_invariants
      sample = @invariant_sampler.call
      append_invariant_sample(sample)
      return reset_invariant_breaches unless sample.breach?

      append_warning(sample.to_warning)
      emit_invariant_warning(sample) if @invariant_policy == :warn
      return if @invariant_policy == :warn

      @consecutive_invariant_breaches += 1
      trigger_stop(:invariant_breach) if @consecutive_invariant_breaches >= 3
    end

    def reset_invariant_breaches
      @consecutive_invariant_breaches = 0 if @invariant_policy == :enforce
    end

    def emit_invariant_warning(sample)
      @stderr.puts("warning: invariant breach: #{sample.breaches.join('; ')}")
    end

    def trigger_stop(reason)
      return unless @runtime.stop_flag.respond_to?(:trigger)

      @runtime.stop_flag.trigger(reason)
    end

    def drain_workers(threads)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + WORKER_DRAIN_TIMEOUT_SECONDS

      threads.each do |thread|
        remaining = [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max
        thread.join(remaining)
        next unless thread.alive?

        thread.kill
        thread.join
      end
    end

    def finish_run
      write_state(window: { end_ts: current_time })
      if stop_reason == :invariant_breach || @window_started
        write_state(outcome: final_outcome)
        return final_exit_code
      end

      write_state(outcome: outcome_payload(aborted: true, error_code: "no_successful_requests"))
      Load::ExitCodes::NO_SUCCESSFUL_REQUESTS
    end

    def final_outcome
      if stop_reason == :invariant_breach
        outcome_payload(aborted: true, error_code: "invariant_breach")
      else
        outcome_payload(aborted: stop_aborted?)
      end
    end

    def final_exit_code
      return Load::ExitCodes::ADAPTER_ERROR if stop_reason == :invariant_breach

      Load::ExitCodes::SUCCESS
    end

    def stop_aborted?
      %i[sigint sigterm].include?(stop_reason)
    end

    def stop_reason
      return nil unless @runtime.stop_flag.respond_to?(:reason)

      @runtime.stop_flag.reason
    end

    def stop_invariant_thread(thread)
      return unless thread
      return if thread == Thread.current

      if invariant_thread_sleeping?
        begin
          thread.raise(InvariantSamplerShutdown.new)
        rescue ThreadError
          nil
        end
      end
      thread.join
    end

    def tracking_buffer
      TrackingBuffer.new(self)
    end

    def pin_window_start
      @state_mutex.synchronize do
        return if @window_started

        @window_started = true
        @state = deep_merge(@state, window: { start_ts: current_time })
        @run_record.write_run(snapshot_state)
      end
    end

    def current_time
      @runtime.clock.call
    end

    public :pin_window_start

    def initial_state
      {
        run_id: File.basename(@run_record.run_dir),
        schema_version: 2,
        workload: {
          name: @workload.name,
          file: workload_file,
          scale: @workload.scale.to_h,
          load_plan: @workload.load_plan.to_h,
          actions: @workload.actions.map { |entry| { class: entry.action_class.name, weight: entry.weight } },
        },
        adapter: {
          describe: nil,
          bin: @settings.adapter_bin || @adapter_client.adapter_bin,
          app_root: @settings.app_root,
          base_url: nil,
          pid: nil,
        },
        window: {
          start_ts: nil,
          end_ts: nil,
          readiness: {
            path: @settings.readiness_path,
            probe_duration_ms: nil,
            probe_attempts: nil,
          },
          startup_grace_seconds: @settings.startup_grace_seconds,
          metrics_interval_seconds: @settings.metrics_interval_seconds,
        },
        outcome: outcome_payload(aborted: false),
        query_ids: [],
        warnings: [],
        invariant_samples: [],
      }
    end

    def workload_file
      return @settings.workload_file if @settings.workload_file

      path = @workload.class.instance_method(:name).source_location&.first
      return nil unless path

      expanded = File.expand_path(path)
      cwd = "#{Dir.pwd}/"
      expanded.start_with?(cwd) ? expanded.delete_prefix(cwd) : expanded
    end

    def outcome_payload(aborted:, error_code: nil)
      request_totals = aggregate_request_totals
      {
        requests_total: request_totals.fetch(:total),
        requests_ok: request_totals.fetch(:ok),
        requests_error: request_totals.fetch(:error),
        aborted:,
        error_code:,
      }.compact
    end

    def snapshot_state
      deep_copy(@state)
    end

    def mark_invariant_thread_sleeping(value)
      @state_mutex.synchronize do
        @invariant_thread_sleeping = value
      end
    end

    def invariant_thread_sleeping?
      @state_mutex.synchronize do
        @invariant_thread_sleeping
      end
    end

    def record_invariant_failure(error)
      @state_mutex.synchronize do
        @invariant_failure ||= error
      end
    end

    def raise_invariant_failure_if_present
      failure = @state_mutex.synchronize do
        error = @invariant_failure
        @invariant_failure = nil
        error
      end
      return unless failure

      raise InvariantSamplerFailure, "invariant sampler failed"
    end

    def stop_adapter_safely(result)
      pid = @state.dig(:adapter, :pid)
      return result unless pid

      @adapter_client.stop(pid:)
      result
    rescue AdapterClient::AdapterError
      if result.nil? || result == Load::ExitCodes::SUCCESS
        write_state(outcome: outcome_payload(aborted: true, error_code: "adapter_error"))
        return Load::ExitCodes::ADAPTER_ERROR
      end

      result
    end

    def write_state(fragment)
      @state_mutex.synchronize do
        @state = deep_merge(@state, fragment)
        @run_record.write_run(snapshot_state)
```

There are three runner details worth noticing in the current branch. First, workers now get `ctx: { base_url:, scale: @workload.scale }`, which is what lets the mixed write actions sample ids from the real workload scale instead of hard-coding user 1 or todo 1. Second, invariant handling is a policy switch in the runner, not in the sampler: `:enforce` increments the consecutive-breach counter and can trigger stop, `:warn` records the same sample but only writes to `stderr`, and `:off` never starts the invariant thread. Third, continuous mode no longer owns the invariant thresholds directly; it just runs the sampler the workload supplied.

`verify-fixture` is a separate pre-flight gate. It is not the same thing as invariant monitoring. The verifier proves the app still has the intended broken query shapes before load starts: a seq scan for `status=open`, N+1 count fan-out on `/api/todos/counts`, and the expected search explain tree. That is why `--invariants off` does not remove the `DATABASE_URL` requirement for `missing-index-todos`: fixture verification still needs live database access.

```bash
sed -n '1,240p' load/lib/load/fixture_verifier.rb
```

```output
# ABOUTME: Verifies the mixed missing-index fixture still exposes its intended pathologies.
# ABOUTME: Checks the bad status scan, counts N+1 query fan-out, and search explain shape.
require "json"
require "pg"

module Load
  class FixtureVerifier
    VerificationError = Class.new(StandardError)

    INDEX_SCAN_NODE_TYPES = ["Index Scan", "Index Only Scan", "Bitmap Index Scan"].freeze
    SEARCH_PLAN_STABLE_KEYS = ["Node Type", "Relation Name", "Sort Key", "Filter", "Plans"].freeze
    COUNTS_PATH = "/api/todos/counts".freeze
    MISSING_INDEX_PATH = "/api/todos?status=open".freeze
    SEARCH_PATH = "/api/todos/search?q=foo".freeze
    MISSING_INDEX_SQL = "EXPLAIN (FORMAT JSON) SELECT * FROM todos WHERE status = 'open'".freeze
    SEARCH_SQL = "EXPLAIN (FORMAT JSON) SELECT * FROM todos WHERE title LIKE '%foo%' ORDER BY created_at DESC LIMIT 50".freeze
    COUNTS_CALLS_SQL = <<~SQL.freeze
      SELECT COALESCE(SUM(calls), 0)::bigint AS calls
      FROM pg_stat_statements
      WHERE query LIKE '%FROM "todos"%'
        AND query LIKE '%COUNT(%'
        AND query LIKE '%"todos"."user_id"%'
    SQL

    def initialize(workload_name:, adapter_bin: nil, app_root: nil, stdout: $stdout, stderr: $stderr, client_factory: nil, explain_reader: nil, stats_reset: nil, counts_calls_reader: nil, search_reference_reader: nil, database_url: ENV["DATABASE_URL"], pg: PG)
      @workload_name = workload_name
      @adapter_bin = adapter_bin
      @app_root = app_root
      @stdout = stdout
      @stderr = stderr
      @client_factory = client_factory || ->(base_url) { Load::Client.new(base_url:) }
      @explain_reader = explain_reader || build_explain_reader(database_url:, pg:)
      @stats_reset = stats_reset || build_stats_reset(database_url:, pg:)
      @counts_calls_reader = counts_calls_reader || build_counts_calls_reader(database_url:, pg:)
      @search_reference_reader = search_reference_reader || -> { JSON.parse(File.read(search_reference_path)).fetch(0).fetch("Plan") }
    end

    def call(base_url:)
      raise ArgumentError, "unknown workload: #{@workload_name}" unless @workload_name == "missing-index-todos"

      {
        ok: true,
        checks: [
          verify_missing_index,
          verify_counts_n_plus_one(base_url:),
          verify_search_rewrite,
        ],
      }
    end

    private

    def verify_missing_index
      plan = @explain_reader.call(MISSING_INDEX_SQL)
      todos_nodes = relation_nodes(plan, "todos")
      rejected_node = todos_nodes.find { |node| INDEX_SCAN_NODE_TYPES.include?(node.fetch("Node Type")) }
      raise VerificationError, "fixture verification failed for #{MISSING_INDEX_PATH}: expected Seq Scan on todos, saw #{rejected_node.fetch("Node Type")}" if rejected_node

      seq_scan = todos_nodes.find do |node|
        node.fetch("Node Type") == "Seq Scan" && node.fetch("Filter", "").include?("status")
      end
      raise VerificationError, "fixture verification failed for #{MISSING_INDEX_PATH}: expected Seq Scan on todos with a status filter" unless seq_scan

      { name: "missing_index", ok: true, node_type: seq_scan.fetch("Node Type") }
    end

    def verify_counts_n_plus_one(base_url:)
      @stats_reset.call
      response = @client_factory.call(base_url).get(COUNTS_PATH)
      ensure_success!(response, COUNTS_PATH)
      users_count = JSON.parse(response.body.to_s).length

      calls = @counts_calls_reader.call.to_i
      if calls < users_count
        raise VerificationError, "fixture verification failed for #{COUNTS_PATH}: expected at least #{users_count} count calls for #{users_count} users, saw #{calls}"
      end

      { name: "counts_n_plus_one", ok: true, calls:, users: users_count }
    end

      def verify_search_rewrite
      plan = @explain_reader.call(SEARCH_SQL)
      reference_plan = @search_reference_reader.call
      unless plan_matches_reference?(actual: plan, reference: reference_plan, keys: SEARCH_PLAN_STABLE_KEYS)
        raise VerificationError, "fixture verification failed for #{SEARCH_PATH}: search explain tree drifted from fixtures/mixed-todo-app/search-explain.json"
      end

      { name: "search_rewrite", ok: true, node_type: plan.fetch("Node Type") }
    end

    def ensure_success!(response, path)
      code = response.code.to_i
      return if code >= 200 && code < 300

      raise VerificationError, "fixture verification failed for #{path}: expected 2xx response, saw #{response.code}"
    end

    def relation_nodes(node, relation_name)
      matches = []
      matches << node if node["Relation Name"] == relation_name
      Array(node["Plans"]).each do |child|
        matches.concat(relation_nodes(child, relation_name))
      end
      matches
    end

    def plan_matches_reference?(actual:, reference:, keys: reference.keys)
      keys.all? do |key|
        next true unless reference.key?(key)

        actual.key?(key) && values_match_reference?(actual.fetch(key), reference.fetch(key), keys:)
      end
    end

    def values_match_reference?(actual, reference, keys:)
      case reference
      when Hash
        actual.is_a?(Hash) && plan_matches_reference?(actual:, reference:, keys:)
      when Array
        actual.is_a?(Array) &&
          actual.length >= reference.length &&
          reference.each_with_index.all? do |child_reference, index|
            values_match_reference?(actual.fetch(index), child_reference, keys:)
          end
      else
        actual == reference
      end
    end

    def build_explain_reader(database_url:, pg:)
      ensure_database_url!(database_url)
      lambda do |sql|
        with_connection(database_url:, pg:) do |connection|
          rows = connection.exec(sql)
          JSON.parse(rows.first.fetch("QUERY PLAN")).fetch(0).fetch("Plan")
        end
      end
    end

    def build_stats_reset(database_url:, pg:)
      ensure_database_url!(database_url)
      lambda do
        with_connection(database_url:, pg:) do |connection|
          connection.exec("SELECT pg_stat_statements_reset()")
        end
      end
    end

    def build_counts_calls_reader(database_url:, pg:)
      ensure_database_url!(database_url)
      lambda do
        with_connection(database_url:, pg:) do |connection|
          connection.exec(COUNTS_CALLS_SQL).first.fetch("calls")
        end
      end
    end

    def with_connection(database_url:, pg:)
      connection = pg.connect(database_url)
      yield connection
    ensure
      connection&.close
    end

    def ensure_database_url!(database_url)
      return database_url unless database_url.nil? || database_url.empty?

      raise ArgumentError, "missing DATABASE_URL for fixture verification"
    end

    def search_reference_path
      File.expand_path("../../../fixtures/mixed-todo-app/search-explain.json", __dir__)
    end
  end
end
```

The Rails adapter still provides the state-changing side of the benchmark. `reset-state` is the key command: it uses a template cache keyed by app root and seed environment, rebuilds the benchmark database when needed, ensures `pg_stat_statements` exists, captures the workload query ids, and resets statement counters again so the actual run starts from a clean slate. That query-id capture is what lets the oracle and ClickHouse side talk about the same statement family later.

```bash
sed -n '1,260p' adapters/rails/lib/rails_adapter/commands/reset_state.rb && printf '\n---\n' && sed -n '1,260p' adapters/rails/lib/rails_adapter/template_cache.rb
```

```output
# ABOUTME: Resets the benchmark database by rebuilding or cloning a template copy.
# ABOUTME: Reruns pg_stat_statements_reset after seeding so run counters start clean.
require "json"
require "uri"

module RailsAdapter
  module Commands
    class ResetState
      QUERY_IDS_SCRIPT = {
        "missing-index-todos" => <<~RUBY.strip,
          require "json"
          Todo.ordered_by_created_desc.with_status("open").page(1, 50).load
          connection = ActiveRecord::Base.connection
          query_ids = [
            %(SELECT "todos".* FROM "todos" WHERE "todos"."status" = $1 ORDER BY "todos"."created_at" DESC, "todos"."id" DESC LIMIT $2 OFFSET $3),
            %(SELECT "todos".* FROM "todos" WHERE "todos"."status" = 'open' ORDER BY "todos"."created_at" DESC, "todos"."id" DESC LIMIT 50 OFFSET 0),
          ].flat_map do |query_text|
            connection.exec_query(
              "SELECT DISTINCT queryid::text AS queryid FROM pg_stat_statements WHERE query = \#{connection.quote(query_text)}"
            ).rows.flatten
          end.uniq
          $stdout.write(JSON.generate(query_ids: query_ids))
        RUBY
      }.freeze

      def initialize(app_root:, seed:, env_pairs:, workload: nil, command_runner: RailsAdapter::CommandRunner.new, template_cache: RailsAdapter::TemplateCache.new, clock: -> { Time.now.to_f })
        @app_root = app_root
        @workload = workload
        @seed = seed
        @env_pairs = env_pairs
        @command_runner = command_runner
        @template_cache = template_cache
        @clock = clock
      end

      def call
        if @template_cache.template_exists?(database_name: database_name, app_root: @app_root, env_pairs: seed_env)
          @template_cache.clone_template(database_name: database_name, app_root: @app_root, env_pairs: seed_env)
        else
          build_template
          @template_cache.build_template(database_name: database_name, app_root: @app_root, env_pairs: seed_env)
        end

        ensure_pg_stat_statements
        query_ids = capture_query_ids
        reset_pg_stat_statements
        RailsAdapter::Result.ok("reset-state", query_ids ? { "query_ids" => query_ids } : {})
      rescue StandardError => error
        RailsAdapter::Result.error("reset-state", "reset_failed", error.message, {})
      end

      private

      def build_template
        drop = @command_runner.capture3("bin/rails", "db:drop", env: rails_env, chdir: @app_root, command_name: "reset-state")
        raise "db:drop failed" unless drop.success?

        migrate = RailsAdapter::Commands::Migrate.new(app_root: @app_root, command_runner: @command_runner).call
        raise "db:create db:schema:load failed" unless migrate.fetch("ok")

        load_dataset = RailsAdapter::Commands::LoadDataset.new(
          app_root: @app_root,
          workload: @workload,
          seed: @seed,
          env_pairs: @env_pairs,
          command_runner: @command_runner,
          clock: @clock,
        ).call
        raise "seed runner failed" unless load_dataset.fetch("ok")
      end

      def reset_pg_stat_statements
        result = @command_runner.capture3(
          "bin/rails",
          "runner",
          %(ActiveRecord::Base.connection.execute("SELECT pg_stat_statements_reset()")),
          env: rails_env,
          chdir: @app_root,
          command_name: "reset-state",
        )
        raise "pg_stat_statements_reset failed" unless result.success?
      end

      def ensure_pg_stat_statements
        result = @command_runner.capture3(
          "bin/rails",
          "runner",
          %(ActiveRecord::Base.connection.execute("CREATE EXTENSION IF NOT EXISTS pg_stat_statements")),
          env: rails_env,
          chdir: @app_root,
          command_name: "reset-state",
        )
        raise "pg_stat_statements extension failed" unless result.success?
      end

      def capture_query_ids
        script = QUERY_IDS_SCRIPT[@workload]
        return nil unless script

        result = @command_runner.capture3(
          "bin/rails",
          "runner",
          script,
          env: rails_env,
          chdir: @app_root,
          command_name: "reset-state",
        )
        raise "query id capture failed" unless result.success?

        JSON.parse(result.stdout).fetch("query_ids")
      end

      def database_name
        return ENV.fetch("BENCHMARK_DB_NAME") if ENV.key?("BENCHMARK_DB_NAME")

        database_url = ENV["DATABASE_URL"]
        return "checkpoint_demo" unless database_url

        path = URI.parse(database_url).path
        name = path.sub(%r{\A/}, "")
        name.empty? ? "checkpoint_demo" : name
      end

      def rails_env
        RailsAdapter::Environment.benchmark(@app_root)
      end

      def seed_env
        @seed_env ||= @env_pairs.merge("SEED" => @seed.to_s)
      end
    end
  end
end

---
# ABOUTME: Manages the adapter-private Postgres template database for fast resets.
# ABOUTME: Uses an admin connection to create, clone, and drop the cached template.
require "digest"
require "uri"

module RailsAdapter
  class TemplateCache
    IDENTIFIER_LIMIT = 63
    TEMPLATE_SUFFIX_LENGTH = "_tmpl_".length + 12 + 1 + 8

    def initialize(pg: nil, admin_url: ENV["BENCH_ADAPTER_PG_ADMIN_URL"] || ENV["DATABASE_URL"])
      @pg = pg
      @admin_url = admin_url
    end

    def template_exists?(database_name:, app_root:, env_pairs: {}, **)
      validate_database_name!(database_name)
      with_connection do |connection|
        connection.exec_params("SELECT 1 FROM pg_database WHERE datname = $1", [template_name(database_name, app_root:, env_pairs:)]).ntuples.positive?
      end
    end

    def build_template(database_name:, app_root:, env_pairs: {}, **)
      validate_database_name!(database_name)
      with_connection do |connection|
        connection.exec("CREATE DATABASE #{template_name(database_name, app_root:, env_pairs:)} TEMPLATE #{database_name}")
      end
    end

    def clone_template(database_name:, app_root:, env_pairs: {}, **)
      validate_database_name!(database_name)
      with_connection do |connection|
        connection.exec_params(<<~SQL, [database_name])
          SELECT pg_terminate_backend(pid)
          FROM pg_stat_activity
          WHERE datname = $1 AND pid <> pg_backend_pid()
        SQL
        connection.exec("DROP DATABASE IF EXISTS #{database_name}")
        connection.exec("CREATE DATABASE #{database_name} TEMPLATE #{template_name(database_name, app_root:, env_pairs:)}")
      end
    end

    private

    def with_connection
      raise "BENCH_ADAPTER_PG_ADMIN_URL or DATABASE_URL is required" unless @admin_url

      uri = URI.parse(@admin_url)
      uri.path = "/postgres"
      connection = pg_driver.connect(uri.to_s)
      yield connection
    ensure
      connection&.close
    end

    def pg_driver
      return @pg if @pg

      require "pg"
      PG
    end

    def template_name(database_name, app_root:, env_pairs:)
      digest = schema_digest(app_root)
      seed_digest = Digest::SHA256.hexdigest(env_pairs.sort.to_a.to_s)[0, 8]
      max_prefix_length = IDENTIFIER_LIMIT - TEMPLATE_SUFFIX_LENGTH
      prefix = database_name[0, max_prefix_length]
      "#{prefix}_tmpl_#{digest}_#{seed_digest}"
    end

    def schema_digest(app_root)
      schema_path = if File.exist?(File.join(app_root, "db", "structure.sql"))
        File.join(app_root, "db", "structure.sql")
      else
        File.join(app_root, "db", "schema.rb")
      end

      Digest::SHA256.file(schema_path).hexdigest[0, 12]
    end

    def validate_database_name!(database_name)
      return if /\A[a-zA-Z_][a-zA-Z0-9_]{0,62}\z/.match?(database_name)

      raise ArgumentError, "invalid database name"
    end
  end
end
```

The workload itself now owns more of the fixture contract. `Load::Scale` carries `rows_per_table`, `seed`, and the extra knobs like `open_fraction`. The workload file uses that scale to define both the mixed action weights and the long-running stationarity guard. The action mix is intentionally lopsided: open-todo reads dominate, but there is enough create, close, delete, count, and search traffic to generate real background noise in `pg_stat_statements` and ClickHouse.

```bash
sed -n '1,260p' workloads/missing_index_todos/actions/list_open_todos.rb && printf '\n---\n' && sed -n '1,260p' workloads/missing_index_todos/actions/list_recent_todos.rb && printf '\n---\n' && sed -n '1,260p' workloads/missing_index_todos/actions/create_todo.rb && printf '\n---\n' && sed -n '1,260p' workloads/missing_index_todos/actions/close_todo.rb && printf '\n---\n' && sed -n '1,260p' workloads/missing_index_todos/actions/delete_completed_todos.rb && printf '\n---\n' && sed -n '1,260p' workloads/missing_index_todos/actions/fetch_counts.rb && printf '\n---\n' && sed -n '1,260p' workloads/missing_index_todos/actions/search_todos.rb
```

```output
# ABOUTME: Defines the open-todos request used to trigger the missing-index workload.
# ABOUTME: Executes the current status-filtered todos endpoint through the shared client.
require_relative "../../../load/lib/load"

module Load
  module Workloads
    module MissingIndexTodos
      module Actions
        class ListOpenTodos < Load::Action
          def name
            :list_open_todos
          end

          def call
            client.get("/api/todos?status=open")
          end
        end
      end
    end
  end
end

---
# ABOUTME: Defines the recent-todos request used in the mixed missing-index workload.
# ABOUTME: Fetches the recent todos page through the shared client with fixed pagination.
require_relative "../../../load/lib/load"

module Load
  module Workloads
    module MissingIndexTodos
      module Actions
        class ListRecentTodos < Load::Action
          def name
            :list_recent_todos
          end

          def call
            client.get("/api/todos?status=all&page=1&per_page=50&order=created_desc")
          end
        end
      end
    end
  end
end

---
# ABOUTME: Defines the create-todo request used in the mixed missing-index workload.
# ABOUTME: Creates a todo through the shared client with a minimal JSON payload.
require_relative "../../../load/lib/load"

module Load
  module Workloads
    module MissingIndexTodos
      module Actions
        class CreateTodo < Load::Action
          def name
            :create_todo
          end

          def call
            client.request(:post, "/api/todos", body: payload)
          end

          private

          def payload
            {
              user_id: ctx.fetch(:user_id) { sample_user_id },
              title: ctx.fetch(:title, "load"),
            }
          end

          def sample_user_id
            scale = ctx[:scale]
            return 1 unless scale

            rng.rand(1..scale.rows_per_table)
          end
        end
      end
    end
  end
end

---
# ABOUTME: Defines the close-todo request used in the mixed missing-index workload.
# ABOUTME: Marks one todo closed through the shared client using a fixture-friendly id.
require_relative "../../../load/lib/load"

module Load
  module Workloads
    module MissingIndexTodos
      module Actions
        class CloseTodo < Load::Action
          def name
            :close_todo
          end

          def call
            client.request(:patch, "/api/todos/#{todo_id}", body: { status: "closed" })
          end

          private

          def todo_id
            ctx.fetch(:todo_id) { sample_todo_id }
          end

          def sample_todo_id
            scale = ctx[:scale]
            return 1 unless scale

            rng.rand(1..scale.rows_per_table)
          end
        end
      end
    end
  end
end

---
# ABOUTME: Defines the delete-completed-todos request used in the mixed missing-index workload.
# ABOUTME: Deletes completed todos with a bounded per-user scope through the shared client.
require_relative "../../../load/lib/load"

module Load
  module Workloads
    module MissingIndexTodos
      module Actions
        class DeleteCompletedTodos < Load::Action
          def name
            :delete_completed_todos
          end

          def call
            client.request(:delete, "/api/todos/completed", body: { user_id: user_id })
          end

          private

          def user_id
            ctx.fetch(:user_id) { sample_user_id }
          end

          def sample_user_id
            scale = ctx[:scale]
            return 1 unless scale

            rng.rand(1..scale.rows_per_table)
          end
        end
      end
    end
  end
end

---
# ABOUTME: Defines the counts request used in the mixed missing-index workload.
# ABOUTME: Fetches aggregate todo counts through the shared client.
require_relative "../../../load/lib/load"

module Load
  module Workloads
    module MissingIndexTodos
      module Actions
        class FetchCounts < Load::Action
          def name
            :fetch_counts
          end

          def call
            client.get("/api/todos/counts")
          end
        end
      end
    end
  end
end

---
# ABOUTME: Defines the search request used in the mixed missing-index workload.
# ABOUTME: Searches todos through the shared client using a fixed default query.
require "uri"

require_relative "../../../load/lib/load"

module Load
  module Workloads
    module MissingIndexTodos
      module Actions
        class SearchTodos < Load::Action
          def name
            :search_todos
          end

          def call
            client.get("/api/todos/search?q=#{URI.encode_www_form_component(query)}")
          end

          private

          def query
            ctx.fetch(:query, "foo")
          end
        end
      end
    end
  end
end
```

On the app side, `db-specialist-demo` is now a small JSON anti-pattern service rather than a single demo endpoint. The controller preserves three separate diagnosis surfaces: `api_index` feeds the missing-index path through `Todo.ordered_by_created_desc.with_status(...).page(...)`, `counts` keeps the count-side N+1 by walking `User.all.index_with { |user| user.todos.count }`, and `search` keeps the `LIKE`-based search query shape. The model scopes encode the workload contract directly: `with_status`, `page`, and `completed_for_user` are exactly the scopes the runner and verifier assume.

```bash
sed -n '1,220p' /home/bjw/db-specialist-demo/config/routes.rb && printf '\n---\n' && sed -n '1,320p' /home/bjw/db-specialist-demo/app/controllers/todos_controller.rb && printf '\n---\n' && sed -n '1,220p' /home/bjw/db-specialist-demo/app/models/todo.rb
```

```output
# ABOUTME: Declares the HTTP routes for the demo todo anti-pattern endpoints.
# ABOUTME: Maps the task routes directly to the controller actions under test.
Rails.application.routes.draw do
  get "/up", to: proc { [200, { "Content-Type" => "text/plain" }, ["ok"]] }
  get "/todos", to: "todos#index"
  get "/todos/status", to: "todos#status"
  get "/todos/stats", to: "todos#stats"

  scope "/api" do
    get "/todos", to: "todos#api_index"
    get "/todos/counts", to: "todos#counts"
    get "/todos/search", to: "todos#search"
    post "/todos", to: "todos#create"
    patch "/todos/:id", to: "todos#update"
    delete "/todos/completed", to: "todos#completed"
  end
end

---
# ABOUTME: Serves the demo todo endpoints that intentionally expose query anti-patterns.
# ABOUTME: Returns todo, status, and per-user stats data for the local collector demo.
class TodosController < ApplicationController
  def index
    todos = params[:q].present? ? Todo.where("title LIKE ?", "%#{params[:q]}%") : Todo.all
    render json: todos.as_json(include: :user)
  end

  def api_index
    order = params[:order].presence
    return head :bad_request if order.present? && order != "created_desc"

    todos = Todo.ordered_by_created_desc
    todos = todos.with_status(params[:status])
    todos = todos.page(params[:page], params[:per_page])

    render json: { items: todos.as_json(only: [:id, :user_id, :title, :status, :created_at, :updated_at]) }
  end

  def create
    todo = Todo.create!(todo_params)

    render json: todo.as_json(only: [:id, :user_id, :title, :status, :created_at, :updated_at]), status: :created
  end

  def update
    todo = Todo.find(params[:id])
    todo.update!(todo_update_params)

    render json: todo.as_json(only: [:id, :user_id, :title, :status, :created_at, :updated_at])
  end

  def completed
    deleted_count = Todo.completed_for_user(params.require(:user_id)).delete_all

    render json: { deleted_count: deleted_count }
  end

  def counts
    render json: User.all.index_with { |user| user.todos.count }.transform_keys { |user| user.id.to_s }
  end

  def search
    items = Todo.where("title LIKE ?", "%#{params[:q]}%").order(created_at: :desc).limit(50)

    render json: { items: items.as_json(only: [:id, :user_id, :title, :status, :created_at, :updated_at]) }
  end

  def status
    render json: Todo.where(status: params.fetch(:status, "open"))
  end

  def stats
    render json: User.all.index_with { |user| user.todos.count }.transform_keys { |user| user.id.to_s }
  end

  private

  def todo_params
    params.permit(:user_id, :title, :status)
  end

  def todo_update_params
    params.permit(:title, :status)
  end
end

---
# ABOUTME: Represents a single todo item in the demo application database.
# ABOUTME: Connects each todo to the owning user for the query log examples.
class Todo < ApplicationRecord
  belongs_to :user, inverse_of: :todos

  scope :ordered_by_created_desc, -> { order(created_at: :desc, id: :desc) }
  scope :completed, -> { where.not(status: "open") }

  def self.with_status(status)
    return all if status.blank? || status == "all"

    where(status: status)
  end

  def self.page(page, per_page)
    current_page = page.to_i
    current_page = 1 if current_page < 1

    page_size = per_page.to_i
    page_size = 50 if page_size < 1

    offset((current_page - 1) * page_size).limit(page_size)
  end

  def self.completed_for_user(user_id)
    where(user_id: user_id).completed
  end
end
```

The oracle stays intentionally narrow even though the fixture got richer. It reads the run record, finds the canonical query ids, checks the live `EXPLAIN` tree for a seq scan on `todos`, waits for ClickHouse to accumulate enough activity on that same query family, and then asserts dominance by estimated total execution time over the next-most-expensive query id. That is the key contract for the agent exercise: many query families may exist, but one should still stand out as the main problem.

```bash
sed -n '1,260p' workloads/missing_index_todos/oracle.rb
```

```output
# ABOUTME: Verifies the missing-index workload reproduced both the bad plan and ClickHouse activity.
# ABOUTME: Reads a run record, tree-walks EXPLAIN JSON, and polls ClickHouse by queryid fingerprints.
require "json"
require "net/http"
require "optparse"
require "pg"
require "time"
require "uri"

module Load
  module Workloads
    module MissingIndexTodos
      class Oracle
        CLICKHOUSE_CALL_THRESHOLD = 500
        DOMINANCE_RATIO_THRESHOLD = 3.0
        INDEX_SCAN_NODE_TYPES = ["Index Scan", "Index Only Scan", "Bitmap Index Scan"].freeze
        CLICKHOUSE_TOPN_LIMIT = 10
        EXPLAIN_SQL = "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT * FROM todos WHERE status = 'open'"
        QUERY_TEXT_CANDIDATES = [
          %(SELECT "todos".* FROM "todos" WHERE "todos"."status" = $1 ORDER BY "todos"."created_at" DESC, "todos"."id" DESC LIMIT $2 OFFSET $3),
          %(SELECT "todos".* FROM "todos" WHERE "todos"."status" = 'open' ORDER BY "todos"."created_at" DESC, "todos"."id" DESC LIMIT 50 OFFSET 0),
        ].freeze

        class Failure < StandardError
        end

        def initialize(stdout: $stdout, stderr: $stderr, pg: PG, clickhouse_query: nil, clickhouse_topn_query: nil, clock: -> { Time.now.utc }, sleeper: ->(seconds) { sleep(seconds) })
          @stdout = stdout
          @stderr = stderr
          @pg = pg
          @clickhouse_query = clickhouse_query || method(:query_clickhouse)
          @clickhouse_topn_query = clickhouse_topn_query || method(:query_clickhouse_topn)
          @clock = clock
          @sleeper = sleeper
        end

        def run(argv)
          options = parse(argv)
          result = call(**options)

          @stdout.puts("PASS: explain (#{result.fetch(:plan).fetch("Node Type")} on todos, plan node confirmed)")
          @stdout.puts("PASS: clickhouse (#{result.fetch(:clickhouse).fetch("total_exec_count")} calls; mean #{result.fetch(:clickhouse).fetch("mean_exec_time_ms")}ms)")
          @stdout.puts(result.fetch(:dominance).fetch("message"))
          exit 0
        rescue Failure => error
          @stderr.puts(error.message)
          exit 1
        end

        def call(run_dir:, database_url:, clickhouse_url:, timeout_seconds: 30)
          run_record = load_run_record(run_dir)
          queryids = extract_queryids(run_record, database_url)
          plan = explain_todos_scan(database_url)
          clickhouse = wait_for_clickhouse!(
            window: run_record.fetch("window"),
            queryids:,
            clickhouse_url:,
            timeout_seconds:
          )
          dominance = assert_dominance(
            window: run_record.fetch("window"),
            expected_queryids: queryids,
            clickhouse_url:,
          )

          {
            plan:,
            clickhouse: normalize_clickhouse_snapshot(clickhouse),
            dominance:,
          }
        end

        private

        def parse(argv)
          options = {
            database_url: ENV["DATABASE_URL"],
            clickhouse_url: ENV["CLICKHOUSE_URL"],
            timeout_seconds: 30,
          }

          parser = OptionParser.new
          parser.on("--database-url URL") { |value| options[:database_url] = value }
          parser.on("--clickhouse-url URL") { |value| options[:clickhouse_url] = value }
          parser.on("--timeout-seconds SECONDS", Integer) { |value| options[:timeout_seconds] = value }

          args = argv.dup
          parser.parse!(args)
          run_dir = args.shift
          raise Failure, "FAIL: missing run record directory" if run_dir.nil? || run_dir.empty?
          raise Failure, "FAIL: missing --database-url (or DATABASE_URL)" if options[:database_url].nil? || options[:database_url].empty?
          raise Failure, "FAIL: missing --clickhouse-url (or CLICKHOUSE_URL)" if options[:clickhouse_url].nil? || options[:clickhouse_url].empty?

          options.merge(run_dir:)
        end

        def load_run_record(run_dir)
          path = File.join(run_dir, "run.json")
          JSON.parse(File.read(path))
        rescue Errno::ENOENT
          raise Failure, "FAIL: missing run record at #{path}"
        end

        def extract_queryids(run_record, database_url)
          candidates = [
            run_record["query_ids"],
            run_record["queryids"],
            run_record.dig("oracle", "query_ids"),
            run_record.dig("oracle", "queryids"),
            run_record.dig("workload", "query_ids"),
            run_record.dig("workload", "queryids"),
            run_record.dig("workload", "oracle", "query_ids"),
            run_record.dig("workload", "oracle", "queryids"),
          ].compact

          queryids = Array(candidates.first).map(&:to_s).reject(&:empty?).uniq
          return queryids unless queryids.empty?

          queryids = lookup_queryids(database_url)
          raise Failure, "FAIL: run record is missing query_ids and pg_stat_statements had no matching queryids" if queryids.empty?

          queryids
        end

        def explain_todos_scan(database_url)
          connection = @pg.connect(database_url)
          rows = connection.exec(EXPLAIN_SQL)
          payload = JSON.parse(rows.first.fetch("QUERY PLAN"))
          plan = payload.fetch(0).fetch("Plan")
          todos_nodes = relation_nodes(plan, "todos")
          raise Failure, "FAIL: explain (could not find todos in plan)" if todos_nodes.empty?

          rejected_node = todos_nodes.find { |node| INDEX_SCAN_NODE_TYPES.include?(node.fetch("Node Type")) }
          raise Failure, "FAIL: explain (expected Seq Scan, got #{rejected_node.fetch("Node Type")})" if rejected_node

          seq_scan = todos_nodes.find { |node| node.fetch("Node Type") == "Seq Scan" }
          return seq_scan if seq_scan

          raise Failure, "FAIL: explain (expected Seq Scan, got #{todos_nodes.first.fetch("Node Type")})"
        ensure
          connection&.close
        end

        def lookup_queryids(database_url)
          connection = @pg.connect(database_url)
          queryids = QUERY_TEXT_CANDIDATES.flat_map do |query_text|
            connection.exec_params(
              "SELECT DISTINCT queryid::text AS queryid FROM pg_stat_statements WHERE query = $1",
              [query_text],
            ).map { |row| row.fetch("queryid") }
          end

          queryids.uniq
        ensure
          connection&.close
        end

        def relation_nodes(node, relation_name)
          matches = []
          matches << node if node["Relation Name"] == relation_name
          Array(node["Plans"]).each do |child|
            matches.concat(relation_nodes(child, relation_name))
          end
          matches
        end

        def wait_for_clickhouse!(window:, queryids:, clickhouse_url:, timeout_seconds:)
          deadline = @clock.call + timeout_seconds

          loop do
            snapshot = normalize_clickhouse_snapshot(
              @clickhouse_query.call(window:, queryids:, clickhouse_url:)
            )
            return snapshot if snapshot.fetch("total_exec_count") >= CLICKHOUSE_CALL_THRESHOLD

            raise Failure, "FAIL: clickhouse (saw #{snapshot.fetch("total_exec_count")} calls before timeout)" if @clock.call >= deadline

            @sleeper.call(1)
          end
        end

        def normalize_clickhouse_snapshot(snapshot)
          {
            "total_exec_count" => snapshot.fetch("total_exec_count").to_i,
            "mean_exec_time_ms" => snapshot.fetch("mean_exec_time_ms", "0.0").to_s,
          }
        end

        def assert_dominance(window:, expected_queryids:, clickhouse_url:)
          rows = @clickhouse_topn_query.call(window:, clickhouse_url:)
          primary = rows.find { |row| expected_queryids.include?(row.fetch("queryid")) }
          raise Failure, "FAIL: dominance (primary queryid not present in top-N)" if primary.nil?

          challenger = rows.find { |row| !expected_queryids.include?(row.fetch("queryid")) }
          if challenger.nil?
            return { "message" => "PASS: dominance (no challenger; primary stands alone)" }
          end

          primary_time = primary.fetch("total_exec_time_ms_estimate").to_f
          challenger_time = challenger.fetch("total_exec_time_ms_estimate").to_f
          ratio = primary_time / challenger_time

          if primary_time >= challenger_time * DOMINANCE_RATIO_THRESHOLD
            { "message" => "PASS: dominance (#{ratio.round(2)}x over next queryid)" }
          else
            raise Failure,
              "FAIL: dominance (#{primary_time}ms / #{challenger_time}ms = #{ratio.round(2)}x; required: >=3x)"
          end
        end

        def query_clickhouse(window:, queryids:, clickhouse_url:)
          uri = URI.parse(clickhouse_url)
          uri.path = "/" if uri.path.nil? || uri.path.empty?
          uri.query = URI.encode_www_form(query: "#{build_clickhouse_sql(window:, queryids:)} FORMAT JSONEachRow")
          response = Net::HTTP.get_response(uri)
          raise Failure, "FAIL: clickhouse (query failed: #{response.code} #{response.body})" if response.code.to_i >= 400

          body = response.body.to_s.each_line.first || "{\"total_exec_count\":\"0\",\"mean_exec_time_ms\":\"0.0\"}"
          JSON.parse(body)
        end

        def query_clickhouse_topn(window:, clickhouse_url:)
          uri = URI.parse(clickhouse_url)
          uri.path = "/" if uri.path.nil? || uri.path.empty?
          uri.query = URI.encode_www_form(query: "#{build_clickhouse_topn_sql(window:)} FORMAT JSONEachRow")
          response = Net::HTTP.get_response(uri)
          raise Failure, "FAIL: clickhouse (query failed: #{response.code} #{response.body})" if response.code.to_i >= 400

          response.body.to_s.each_line.map { |line| JSON.parse(line) }
        end

        def build_clickhouse_sql(window:, queryids:)
          escaped_queryids = queryids.map { |queryid| "'#{queryid.gsub("'", "''")}'" }.join(", ")

          <<~SQL
            SELECT
              toString(coalesce(sum(total_exec_count), 0)) AS total_exec_count,
              toString(round(coalesce(avg(avg_exec_time_ms), 0), 1)) AS mean_exec_time_ms
            FROM query_intervals
            WHERE interval_ended_at BETWEEN parseDateTime64BestEffort('#{window.fetch("start_ts")}') AND parseDateTime64BestEffort('#{window.fetch("end_ts")}') + INTERVAL 90 SECOND
              AND queryid IN (#{escaped_queryids})
          SQL
        end

        def build_clickhouse_topn_sql(window:)
          <<~SQL
            SELECT
              toString(queryid) AS queryid,
              toString(sum(total_exec_count)) AS total_calls,
              toString(round(sum(total_exec_count * avg_exec_time_ms), 1)) AS total_exec_time_ms_estimate
            FROM query_intervals
            WHERE interval_ended_at BETWEEN parseDateTime64BestEffort('#{window.fetch("start_ts")}')
              AND parseDateTime64BestEffort('#{window.fetch("end_ts")}') + INTERVAL 90 SECOND
            GROUP BY queryid
            ORDER BY sum(total_exec_count * avg_exec_time_ms) DESC
            LIMIT #{CLICKHOUSE_TOPN_LIMIT}
          SQL
        end
      end
    end
```

Two run artifacts from this branch make the operator modes concrete. The `warn` soak run shows what happens when the dataset is deliberately degraded: fixture verification passed up front, the soak kept running, one invariant breach was recorded in `warnings` and `invariant_samples`, and `stderr` received a warning line, but the run did not stop with `error_code: invariant_breach`. The `off` soak run shows the opposite: fixture verification still ran, but invariant sampling produced no samples and no warnings.

```bash
for dir in runs/20260425T183552Z-missing-index-todos runs/20260425T184005Z-missing-index-todos; do echo "=== $dir ==="; sed -n "1,220p" "$dir/run.json"; echo; done; printf "\n--- WARN STDERR ---\n"; sed -n "1,40p" /tmp/soak_warn.err; printf "\n--- OFF STDERR ---\n"; sed -n "1,40p" /tmp/soak_off.err
```

```output
=== runs/20260425T183552Z-missing-index-todos ===
{
  "run_id": "20260425T183552Z-missing-index-todos",
  "schema_version": 1,
  "workload": {
    "name": "missing-index-todos",
    "file": "/home/bjw/checkpoint-collector/workloads/missing_index_todos/workload",
    "scale": {
      "rows_per_table": 100000,
      "seed": 42,
      "extra": {
        "open_fraction": 0.6
      }
    },
    "load_plan": {
      "workers": 16,
      "duration_seconds": 60,
      "rate_limit": "unlimited",
      "seed": null
    },
    "actions": [
      {
        "class": "Load::Workloads::MissingIndexTodos::Actions::ListOpenTodos",
        "weight": 68
      },
      {
        "class": "Load::Workloads::MissingIndexTodos::Actions::ListRecentTodos",
        "weight": 12
      },
      {
        "class": "Load::Workloads::MissingIndexTodos::Actions::CreateTodo",
        "weight": 7
      },
      {
        "class": "Load::Workloads::MissingIndexTodos::Actions::CloseTodo",
        "weight": 7
      },
      {
        "class": "Load::Workloads::MissingIndexTodos::Actions::DeleteCompletedTodos",
        "weight": 3
      },
      {
        "class": "Load::Workloads::MissingIndexTodos::Actions::FetchCounts",
        "weight": 2
      },
      {
        "class": "Load::Workloads::MissingIndexTodos::Actions::SearchTodos",
        "weight": 3
      }
    ]
  },
  "adapter": {
    "describe": {
      "ok": true,
      "command": "describe",
      "name": "rails-postgres-adapter",
      "framework": "rails",
      "runtime": "ruby-3.2.3"
    },
    "bin": "adapters/rails/bin/bench-adapter",
    "app_root": "/home/bjw/db-specialist-demo",
    "base_url": "http://127.0.0.1:3000",
    "pid": 978380
  },
  "window": {
    "start_ts": "2026-04-25 18:36:04 UTC",
    "end_ts": "2026-04-25 18:37:18 UTC",
    "readiness": {
      "path": "/up",
      "probe_duration_ms": 1651,
      "probe_attempts": 4,
      "completed_at": "2026-04-25 18:36:01 UTC"
    },
    "startup_grace_seconds": 15.0,
    "metrics_interval_seconds": 5.0
  },
  "outcome": {
    "requests_total": 1983,
    "requests_ok": 1962,
    "requests_error": 21,
    "aborted": true
  },
  "query_ids": [
    "8287095973081652108"
  ],
  "warnings": [
    {
      "type": "invariant_breach",
      "message": "open_count 0 is below open_floor 30000; total_count -1 is below total_floor 80000",
      "open_count": 0,
      "total_count": -1,
      "open_floor": 30000,
      "total_floor": 80000,
      "total_ceiling": 200000
    }
  ],
  "invariant_samples": [
    {
      "sampled_at": "2026-04-25 18:37:07 UTC",
      "open_count": 0,
      "total_count": -1,
      "open_floor": 30000,
      "total_floor": 80000,
      "total_ceiling": 200000,
      "breach": true,
      "breaches": [
        "open_count 0 is below open_floor 30000",
        "total_count -1 is below total_floor 80000"
      ]
    }
  ]
}

=== runs/20260425T184005Z-missing-index-todos ===
{
  "run_id": "20260425T184005Z-missing-index-todos",
  "schema_version": 1,
  "workload": {
    "name": "missing-index-todos",
    "file": "/home/bjw/checkpoint-collector/workloads/missing_index_todos/workload",
    "scale": {
      "rows_per_table": 100000,
      "seed": 42,
      "extra": {
        "open_fraction": 0.6
      }
    },
    "load_plan": {
      "workers": 16,
      "duration_seconds": 60,
      "rate_limit": "unlimited",
      "seed": null
    },
    "actions": [
      {
        "class": "Load::Workloads::MissingIndexTodos::Actions::ListOpenTodos",
        "weight": 68
      },
      {
        "class": "Load::Workloads::MissingIndexTodos::Actions::ListRecentTodos",
        "weight": 12
      },
      {
        "class": "Load::Workloads::MissingIndexTodos::Actions::CreateTodo",
        "weight": 7
      },
      {
        "class": "Load::Workloads::MissingIndexTodos::Actions::CloseTodo",
        "weight": 7
      },
      {
        "class": "Load::Workloads::MissingIndexTodos::Actions::DeleteCompletedTodos",
        "weight": 3
      },
      {
        "class": "Load::Workloads::MissingIndexTodos::Actions::FetchCounts",
        "weight": 2
      },
      {
        "class": "Load::Workloads::MissingIndexTodos::Actions::SearchTodos",
        "weight": 3
      }
    ]
  },
  "adapter": {
    "describe": {
      "ok": true,
      "command": "describe",
      "name": "rails-postgres-adapter",
      "framework": "rails",
      "runtime": "ruby-3.2.3"
    },
    "bin": "adapters/rails/bin/bench-adapter",
    "app_root": "/home/bjw/db-specialist-demo",
    "base_url": "http://127.0.0.1:3000",
    "pid": 984756
  },
  "window": {
    "start_ts": "2026-04-25 18:40:15 UTC",
    "end_ts": "2026-04-25 18:40:19 UTC",
    "readiness": {
      "path": "/up",
      "probe_duration_ms": 1646,
      "probe_attempts": 4,
      "completed_at": "2026-04-25 18:40:13 UTC"
    },
    "startup_grace_seconds": 15.0,
    "metrics_interval_seconds": 5.0
  },
  "outcome": {
    "requests_total": 169,
    "requests_ok": 169,
    "requests_error": 0,
    "aborted": true
  },
  "query_ids": [
    "8287095973081652108"
  ],
  "warnings": [

  ],
  "invariant_samples": [

  ]
}


--- WARN STDERR ---
warning: invariant breach: open_count 0 is below open_floor 30000; total_count -1 is below total_floor 80000

--- OFF STDERR ---
```

End to end, the current branch now has a clearer responsibility split than the original mixed-fixture cut. `bin/load` and `Load::CLI` choose the mode and parse operator policy, the workload supplies the scale, actions, and invariant sampler, the runner handles generic execution and policy enforcement, `FixtureVerifier` protects the pre-flight broken-app contract, the Rails adapter resets and fingerprints the database state, and the oracle judges whether the dominant missing-index pathology actually won the noisy mixed run. That is the full path an agent sees when it starts from `checkpoint-collector` and a live stack rather than from the demo app repo.

