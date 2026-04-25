# Mixed Missing-Index Todo Fixture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the narrow `missing-index-todos` fixture with a richer Todo JSON benchmark app and mixed workload while keeping the missing-index oracle dominant, adding `verify-fixture`, and supporting both finite and soak execution modes.

**Architecture:** Extend `~/db-specialist-demo` into a TodoMVC-shaped JSON API that intentionally preserves three pathologies, then evolve `checkpoint-collector` so `bin/load` can run the mixed workload in both finite and continuous modes. Keep the formal oracle narrow on the missing-index path, but add a pre-flight `verify-fixture` gate and soak-mode invariant sampling so the diagnosis exercise fails loudly when the fixture drifts out of its designed regime.

**Tech Stack:** Ruby, Rails, Minitest, PostgreSQL, ClickHouse, existing `bin/load` runner, existing Rails adapter, shell/Makefile wiring.

---

## File Map

### `checkpoint-collector`

- Create: `load/lib/load/fixture_verifier.rb`
  - Runs the three pre-flight fixture assertions against a freshly reset app.
- Create: `load/test/fixture_verifier_test.rb`
  - Unit tests for `Load::FixtureVerifier`.
- Create: `load/test/soak_target_test.rb`
  - Locks the Makefile/README/CLI soak workflow.
- Create: `workloads/missing_index_todos/actions/create_todo.rb`
  - Mixed workload create action.
- Create: `workloads/missing_index_todos/actions/close_todo.rb`
  - Mixed workload close action.
- Create: `workloads/missing_index_todos/actions/list_recent_todos.rb`
  - Mixed workload paginated list action.
- Create: `workloads/missing_index_todos/actions/delete_completed_todos.rb`
  - Mixed workload bounded bulk-delete action.
- Create: `workloads/missing_index_todos/actions/fetch_counts.rb`
  - Mixed workload N+1 counts action.
- Create: `workloads/missing_index_todos/actions/search_todos.rb`
  - Mixed workload search action.
- Create: `workloads/missing_index_todos/test/actions_test.rb`
  - Action request-shape tests.
- Create: `fixtures/mixed-todo-app/search-explain.json`
  - Golden rewrite-like explain pattern used by `verify-fixture`.

- Modify: `bin/load`
  - Support `verify-fixture` and `soak`.
- Modify: `load/lib/load/cli.rb`
  - Parse new commands/options and route to runner/verifier.
- Modify: `load/lib/load/run_record.rb`
  - Persist soak warnings/invariant samples and `verify-fixture` outcomes.
- Modify: `load/lib/load/runner.rb`
  - Add soak execution path, pre-flight verifier call, invariant sampling, and clean abort behavior.
- Modify: `load/lib/load/adapter_client.rb`
  - Reuse existing contract for reset/start/stop from new commands without widening the adapter surface.
- Modify: `load/test/cli_test.rb`
  - Cover `verify-fixture` and `soak` command parsing/exit paths.
- Modify: `load/test/runner_test.rb`
  - Cover pre-flight gate, soak sampling, and sustained-breach abort behavior.
- Modify: `load/test/load_smoke_target_test.rb`
  - Update Makefile expectations for new targets.
- Modify: `workloads/missing_index_todos/workload.rb`
  - Replace single action with mixed action entries and updated default scale.
- Modify: `workloads/missing_index_todos/oracle.rb`
  - Keep missing-index assertion, add dominance-margin assertion via ClickHouse.
- Modify: `workloads/missing_index_todos/test/workload_test.rb`
  - Lock the new action mix, scale, and load plans.
- Modify: `workloads/missing_index_todos/test/oracle_test.rb`
  - Cover dominance-margin pass/fail and existing explain/clickhouse assertions.
- Modify: `README.md`
  - Document finite runs, soak mode, `verify-fixture`, and artifact interpretation.
- Modify: `Makefile`
  - Add `verify-fixture` / soak helper targets if needed.
- Modify: `JOURNAL.md`
  - Record key implementation decisions and verification findings.

### `db-specialist-demo`

- Create or modify as needed:
  - `config/routes.rb`
  - `app/controllers/todos_controller.rb`
  - `app/models/todo.rb`
  - `app/models/user.rb`
  - `db/seeds.rb`
  - `test/controllers/todos_controller_test.rb`
  - `test/integration/...` if route-level coverage wants a separate file
  - CI wiring file(s) already used by the repo for required checks

Responsibility:
- add the Todo JSON API
- preserve the missing `status` index
- preserve counts N+1 and rewrite-like search pathology
- make delete bounded
- keep seed data compatible with the workload invariants
- shell out to `checkpoint-collector/bin/load verify-fixture` in CI

## Task 1: Lock The New CLI Contract

**Files:**
- Modify: `load/test/cli_test.rb`
- Modify: `bin/load`
- Modify: `load/lib/load/cli.rb`

- [ ] **Step 1: Write the failing CLI tests for `verify-fixture` and `soak`**

```ruby
def test_cli_runs_verify_fixture_command
  verifier = Minitest::Mock.new
  verifier.expect(:call, 0)

  cli = Load::CLI.new(
    argv: ["verify-fixture", "--workload", "missing-index-todos", "--adapter", "adapters/rails/bin/bench-adapter", "--app-root", "/tmp/demo"],
    version: "0.3.0",
    verifier_factory: ->(**kwargs) { assert_equal "missing-index-todos", kwargs.fetch(:workload_name); verifier },
    stdout: StringIO.new,
    stderr: StringIO.new
  )

  assert_equal 0, cli.run
  verifier.verify
end

def test_cli_runs_soak_command
  runner = Minitest::Mock.new
  runner.expect(:run, Load::ExitCodes::OK)

  cli = Load::CLI.new(
    argv: ["soak", "--workload", "missing-index-todos", "--adapter", "adapters/rails/bin/bench-adapter", "--app-root", "/tmp/demo"],
    version: "0.3.0",
    runner_factory: ->(**kwargs) { assert_equal :continuous, kwargs.fetch(:mode); runner },
    stdout: StringIO.new,
    stderr: StringIO.new
  )

  assert_equal Load::ExitCodes::OK, cli.run
  runner.verify
end
```

- [ ] **Step 2: Run the CLI tests to verify they fail**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/cli_test.rb`

Expected: FAIL because `verify-fixture` and `soak` are unknown commands or because the new factories/kwargs do not exist yet.

- [ ] **Step 3: Implement the minimal CLI changes**

```ruby
case command
when "run"
  run_command(mode: :finite)
when "soak"
  run_command(mode: :continuous)
when "verify-fixture"
  verify_fixture_command
```

```ruby
def verify_fixture_command
  options = parse_shared_options(@argv)
  verifier = @verifier_factory.call(
    workload_name: options.fetch(:workload),
    adapter_bin: options.fetch(:adapter_bin),
    app_root: options.fetch(:app_root),
    stdout: @stdout,
    stderr: @stderr
  )
  verifier.call
end
```

- [ ] **Step 4: Run the CLI tests to verify they pass**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/cli_test.rb`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add bin/load load/lib/load/cli.rb load/test/cli_test.rb
git commit -m "feat: add soak and verify-fixture commands"
```

## Task 2: Add The Mixed Workload Actions

**Files:**
- Create: `workloads/missing_index_todos/actions/create_todo.rb`
- Create: `workloads/missing_index_todos/actions/close_todo.rb`
- Create: `workloads/missing_index_todos/actions/list_recent_todos.rb`
- Create: `workloads/missing_index_todos/actions/delete_completed_todos.rb`
- Create: `workloads/missing_index_todos/actions/fetch_counts.rb`
- Create: `workloads/missing_index_todos/actions/search_todos.rb`
- Create: `workloads/missing_index_todos/test/actions_test.rb`
- Modify: `workloads/missing_index_todos/workload.rb`
- Modify: `workloads/missing_index_todos/test/workload_test.rb`

- [ ] **Step 1: Write failing tests for the new action request shapes and workload mix**

```ruby
def test_actions_issue_expected_requests
  http = FakeHttp.new
  base_url = "http://127.0.0.1:3000"

  Workloads::MissingIndexTodos::Actions::CreateTodo.new.call(client(base_url, http))
  Workloads::MissingIndexTodos::Actions::ListRecentTodos.new.call(client(base_url, http))
  Workloads::MissingIndexTodos::Actions::FetchCounts.new.call(client(base_url, http))
  Workloads::MissingIndexTodos::Actions::SearchTodos.new(query: "foo").call(client(base_url, http))

  assert_includes http.requests, [:post, "/api/todos"]
  assert_includes http.requests, [:get, "/api/todos?status=all&page=1&per_page=50&order=created_desc"]
  assert_includes http.requests, [:get, "/api/todos/counts"]
  assert_includes http.requests, [:get, "/api/todos/search?q=foo"]
end

def test_workload_declares_mixed_action_entries
  workload = Load::Workloads::MissingIndexTodos::Workload.new

  names = workload.actions.map { |entry| entry.action_class.name.split("::").last }
  assert_equal %w[ListOpenTodos ListRecentTodos CreateTodo CloseTodo DeleteCompletedTodos FetchCounts SearchTodos], names
  assert_equal 100_000, workload.scale.rows_per_table
  assert_equal 0.6, workload.scale.open_fraction
end
```

- [ ] **Step 2: Run workload tests to verify they fail**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby workloads/missing_index_todos/test/workload_test.rb && BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby workloads/missing_index_todos/test/actions_test.rb`

Expected: FAIL because the new action classes and mixed action entries do not exist yet.

- [ ] **Step 3: Implement the minimal action classes and workload changes**

```ruby
class CreateTodo < Load::Action
  def call(client)
    client.post_json("/api/todos", {user_id: 1, title: "load #{Process.clock_gettime(Process::CLOCK_MONOTONIC)}"})
  end
end
```

```ruby
def actions
  [
    Load::ActionEntry.new(Actions::ListOpenTodos, 68),
    Load::ActionEntry.new(Actions::ListRecentTodos, 12),
    Load::ActionEntry.new(Actions::CreateTodo, 7),
    Load::ActionEntry.new(Actions::CloseTodo, 7),
    Load::ActionEntry.new(Actions::DeleteCompletedTodos, 3),
    Load::ActionEntry.new(Actions::FetchCounts, 6),
    Load::ActionEntry.new(Actions::SearchTodos, 3)
  ]
end
```

- [ ] **Step 4: Run the workload tests to verify they pass**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby workloads/missing_index_todos/test/actions_test.rb && BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby workloads/missing_index_todos/test/workload_test.rb`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add workloads/missing_index_todos/actions workloads/missing_index_todos/workload.rb workloads/missing_index_todos/test/actions_test.rb workloads/missing_index_todos/test/workload_test.rb
git commit -m "feat: define mixed missing-index workload"
```

## Task 3: Extend The Demo App API Without Losing The Broken Schema

**Files:**
- Modify: `/home/bjw/db-specialist-demo/config/routes.rb`
- Modify: `/home/bjw/db-specialist-demo/app/controllers/todos_controller.rb`
- Modify: `/home/bjw/db-specialist-demo/app/models/todo.rb`
- Modify: `/home/bjw/db-specialist-demo/app/models/user.rb`
- Modify: `/home/bjw/db-specialist-demo/test/controllers/todos_controller_test.rb`

- [ ] **Step 1: Write failing route/controller tests for the JSON API**

```ruby
test "lists open todos newest first" do
  get "/api/todos", params: {status: "open", page: 1, per_page: 50, order: "created_desc"}
  assert_response :success
  body = JSON.parse(@response.body)
  assert_equal "open", body.fetch("items").first.fetch("status")
end

test "creates and closes a todo" do
  post "/api/todos", params: {user_id: users(:one).id, title: "from test"}, as: :json
  assert_response :created
  todo_id = JSON.parse(@response.body).fetch("id")

  patch "/api/todos/#{todo_id}", params: {status: "closed"}, as: :json
  assert_response :success
  assert_equal "closed", Todo.find(todo_id).status
end

test "delete completed is bounded per call" do
  assert_changes -> { Todo.where.not(status: "open").count }, from: 10 do
    delete "/api/todos/completed", params: {user_id: users(:one).id}, as: :json
  end
  assert_operator Todo.where.not(status: "open").count, :>, 0
end
```

- [ ] **Step 2: Run the demo-app controller tests to verify they fail**

Run: `BUNDLE_USER_HOME=/tmp/bundle BUNDLE_PATH=vendor/bundle bundle exec rails test test/controllers/todos_controller_test.rb`

Expected: FAIL because the new JSON routes/actions do not exist yet.

- [ ] **Step 3: Implement the minimal routes and controller/model code**

```ruby
scope "/api" do
  resources :todos, only: [:index, :create, :update] do
    collection do
      delete :completed
      get :counts
      get :search
    end
  end
end
```

```ruby
def index
  scope = Todo.order(created_at: :desc)
  scope = scope.where(status: params[:status]) unless params[:status].in?(%w[all nil]) || params[:status].blank?
  scope = scope.page(params[:page]).per(params[:per_page] || 50)
  render json: {items: scope.as_json(only: [:id, :user_id, :title, :status, :created_at])}
end
```

- [ ] **Step 4: Run the demo-app controller tests to verify they pass**

Run: `BUNDLE_USER_HOME=/tmp/bundle BUNDLE_PATH=vendor/bundle bundle exec rails test test/controllers/todos_controller_test.rb`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git -C /home/bjw/db-specialist-demo add config/routes.rb app/controllers/todos_controller.rb app/models/todo.rb app/models/user.rb test/controllers/todos_controller_test.rb
git -C /home/bjw/db-specialist-demo commit -m "feat: add todo benchmark api"
```

## Task 4: Preserve The Count N+1 And Search Pathologies Explicitly

**Files:**
- Modify: `/home/bjw/db-specialist-demo/app/controllers/todos_controller.rb`
- Modify: `/home/bjw/db-specialist-demo/test/controllers/todos_controller_test.rb`
- Create: `fixtures/mixed-todo-app/search-explain.json`

- [ ] **Step 1: Write failing tests that lock the counts and search behavior at the API boundary**

```ruby
test "counts returns per-user totals" do
  get "/api/todos/counts"
  assert_response :success
  body = JSON.parse(@response.body)
  assert body.key?(users(:one).id.to_s)
end

test "search returns matching todos" do
  get "/api/todos/search", params: {q: "alpha"}
  assert_response :success
  body = JSON.parse(@response.body)
  assert body.fetch("items").all? { |item| item.fetch("title").include?("alpha") }
end
```

- [ ] **Step 2: Run the demo-app tests to verify they fail**

Run: `BUNDLE_USER_HOME=/tmp/bundle BUNDLE_PATH=vendor/bundle bundle exec rails test test/controllers/todos_controller_test.rb`

Expected: FAIL because the counts/search endpoints are incomplete or absent.

- [ ] **Step 3: Implement the minimal broken behavior and capture the search explain reference**

```ruby
def counts
  render json: User.all.index_with { |user| user.todos.count }.transform_keys { |user| user.id.to_s }
end

def search
  items = Todo.where("title LIKE ?", "%#{params[:q]}%").order(created_at: :desc).limit(50)
  render json: {items: items.as_json(only: [:id, :user_id, :title, :status, :created_at])}
end
```

```bash
psql postgres://postgres:postgres@localhost:5432/checkpoint_demo -c \
  "EXPLAIN (FORMAT JSON) SELECT * FROM todos WHERE title LIKE '%foo%' ORDER BY created_at DESC LIMIT 50" \
  > fixtures/mixed-todo-app/search-explain.json
```

- [ ] **Step 4: Run the demo-app tests to verify they pass**

Run: `BUNDLE_USER_HOME=/tmp/bundle BUNDLE_PATH=vendor/bundle bundle exec rails test test/controllers/todos_controller_test.rb`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git -C /home/bjw/db-specialist-demo add app/controllers/todos_controller.rb test/controllers/todos_controller_test.rb
git add fixtures/mixed-todo-app/search-explain.json
git -C /home/bjw/db-specialist-demo commit -m "feat: preserve todo benchmark pathologies"
git add fixtures/mixed-todo-app/search-explain.json
git commit -m "test: add search explain fixture"
```

## Task 5: Retune The Demo Seed Data For Dominance And Soak Stability

**Files:**
- Modify: `/home/bjw/db-specialist-demo/db/seeds.rb`
- Modify: `/home/bjw/db-specialist-demo/test/...` if the demo repo already has seed coverage, otherwise add a narrow script-backed test
- Modify: `workloads/missing_index_todos/workload.rb`

- [ ] **Step 1: Write a failing seed smoke test or script-backed assertion for the new scale**

```ruby
def test_seed_respects_rows_and_open_fraction
  run_seed(rows_per_table: 100_000, open_fraction: 0.6, seed: 42)

  assert_equal 100_000, Todo.count
  assert_in_delta 60_000, Todo.where(status: "open").count, 2_000
end
```

- [ ] **Step 2: Run the seed test to verify it fails**

Run: `BUNDLE_USER_HOME=/tmp/bundle BUNDLE_PATH=vendor/bundle bundle exec rails test test/models/seed_test.rb`

Expected: FAIL or missing test file, because the current seed distribution still targets the earlier fixture assumptions.

- [ ] **Step 3: Implement the minimal seed changes**

```ruby
rows = Integer(ENV.fetch("ROWS_PER_TABLE", "100000"))
open_fraction = Float(ENV.fetch("OPEN_FRACTION", "0.6"))
random = Random.new(Integer(ENV.fetch("SEED", "42")))

rows.times do |index|
  status = random.rand < open_fraction ? "open" : "closed"
  Todo.create!(user: users[index % users.length], title: "todo #{index}", status: status)
end
```

- [ ] **Step 4: Run the seed test to verify it passes**

Run: `BUNDLE_USER_HOME=/tmp/bundle BUNDLE_PATH=vendor/bundle bundle exec rails test test/models/seed_test.rb`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git -C /home/bjw/db-specialist-demo add db/seeds.rb test/models/seed_test.rb
git -C /home/bjw/db-specialist-demo commit -m "feat: retune benchmark seed distribution"
```

## Task 6: Build `verify-fixture`

**Files:**
- Create: `load/lib/load/fixture_verifier.rb`
- Create: `load/test/fixture_verifier_test.rb`
- Modify: `load/lib/load.rb` or equivalent require list
- Modify: `load/lib/load/client.rb` only if a helper method is missing

- [ ] **Step 1: Write failing verifier tests for all three assertions**

```ruby
def test_verify_fixture_checks_missing_index_counts_and_search
  verifier = Load::FixtureVerifier.new(
    workload_name: "missing-index-todos",
    adapter_client: fake_adapter_client,
    explain_reader: fake_explain_reader(
      open_plan: seq_scan_plan("status"),
      search_plan: search_reference_plan
    ),
    stats_reader: fake_stats_reader(queryids: ["1", "2"])
  )

  result = verifier.call

  assert_equal true, result.fetch(:ok)
  assert_equal %w[missing_index counts_n_plus_one search_rewrite], result.fetch(:checks).map { |check| check.fetch(:name) }
end

def test_verify_fixture_fails_when_counts_collapse_to_one_queryid
  verifier = Load::FixtureVerifier.new(...stats_reader: fake_stats_reader(queryids: ["1"]))
  error = assert_raises(Load::FixtureVerifier::VerificationError) { verifier.call }
  assert_includes error.message, "/api/todos/counts"
end
```

- [ ] **Step 2: Run the verifier tests to verify they fail**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/fixture_verifier_test.rb`

Expected: FAIL because `Load::FixtureVerifier` does not exist yet.

- [ ] **Step 3: Implement the minimal verifier**

```ruby
class Load::FixtureVerifier
  def call
    checks = []
    checks << verify_missing_index
    checks << verify_counts_n_plus_one
    checks << verify_search_rewrite
    {ok: true, checks: checks}
  end
end
```

```ruby
def verify_counts_n_plus_one
  adapter_client.reset_stats
  client.get("/api/todos/counts")
  queryids = stats_reader.queryids_for_last_request
  raise VerificationError, "counts pathology missing for /api/todos/counts" unless queryids.length >= 2
  {name: "counts_n_plus_one", ok: true}
end
```

- [ ] **Step 4: Run the verifier tests to verify they pass**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/fixture_verifier_test.rb`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add load/lib/load/fixture_verifier.rb load/test/fixture_verifier_test.rb load/lib/load.rb
git commit -m "feat: add fixture verification preflight"
```

## Task 7: Gate Finite Runs On `verify-fixture`

**Files:**
- Modify: `load/lib/load/runner.rb`
- Modify: `load/test/runner_test.rb`
- Modify: `load/lib/load/cli.rb` if runner args need the verifier instance

- [ ] **Step 1: Write failing runner tests for pre-flight gating**

```ruby
def test_runner_calls_verify_fixture_before_starting_adapter
  verifier = Minitest::Mock.new
  verifier.expect(:call, {ok: true})
  adapter = fake_adapter_client

  runner = build_runner(mode: :finite, adapter_client: adapter, verifier: verifier)
  runner.run

  verifier.verify
  assert_equal [:describe, :prepare, :reset_state, :start, :stop], adapter.calls
end

def test_runner_aborts_before_start_when_verify_fixture_fails
  runner = build_runner(mode: :finite, verifier: -> { raise Load::FixtureVerifier::VerificationError, "counts pathology missing" })
  assert_equal Load::ExitCodes::ERROR, runner.run
  refute File.exist?(File.join(runner.run_record.run_dir, "metrics.jsonl"))
end
```

- [ ] **Step 2: Run the runner tests to verify they fail**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb`

Expected: FAIL because the runner does not invoke `verify-fixture` yet.

- [ ] **Step 3: Implement the minimal pre-flight gate**

```ruby
def run
  result = Load::ExitCodes::OK
  verifier.call
  boot_adapter
  ...
end
```

```ruby
rescue Load::FixtureVerifier::VerificationError => error
  write_state(error_code: "fixture_verification_failed", error_message: error.message)
  result = Load::ExitCodes::ERROR
```

- [ ] **Step 4: Run the runner tests to verify they pass**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add load/lib/load/runner.rb load/test/runner_test.rb load/lib/load/cli.rb
git commit -m "feat: gate runs on fixture verification"
```

## Task 8: Add Soak Mode And Invariant Sampling

**Files:**
- Modify: `load/lib/load/runner.rb`
- Modify: `load/lib/load/run_record.rb`
- Modify: `load/test/runner_test.rb`
- Modify: `load/test/run_record_test.rb`

- [ ] **Step 1: Write failing tests for continuous mode and invariant breaches**

```ruby
def test_soak_mode_runs_until_stop_flag
  stop_flag = Load::Runner::InternalStopFlag.new
  runner = build_runner(mode: :continuous, stop_flag: stop_flag)

  thread = Thread.new { runner.run }
  sleep 0.1
  stop_flag.trigger(:sigterm)

  assert_equal Load::ExitCodes::ABORTED, thread.value
end

def test_runner_aborts_after_three_sustained_invariant_breaches
  sampler = fake_sampler([
    {open_count: 100, total_count: 10_000},
    {open_count: 100, total_count: 10_000},
    {open_count: 100, total_count: 10_000}
  ])

  runner = build_runner(mode: :continuous, invariant_sampler: sampler)
  assert_equal Load::ExitCodes::ERROR, runner.run
  assert_includes runner.run_record.read_run_json.fetch("warnings").last.fetch("message"), "open_count"
end
```

- [ ] **Step 2: Run the runner/run-record tests to verify they fail**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb && BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/run_record_test.rb`

Expected: FAIL because continuous mode and warning persistence do not exist yet.

- [ ] **Step 3: Implement the minimal soak path**

```ruby
def execute_window
  return wait_for_stop_signal if mode == :continuous
  wait_for_window_end
end
```

```ruby
def sample_invariants
  sample = invariant_sampler.call
  run_record.append_warning(sample.to_h) if sample.breach?
  @sustained_breaches += 1 if sample.breach?
  trigger_stop(:invariant_breach) if @sustained_breaches >= 3
end
```

- [ ] **Step 4: Run the soak tests to verify they pass**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb && BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/run_record_test.rb`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add load/lib/load/runner.rb load/lib/load/run_record.rb load/test/runner_test.rb load/test/run_record_test.rb
git commit -m "feat: add soak mode invariant sampling"
```

## Task 9: Strengthen The Oracle With Dominance Margin

**Files:**
- Modify: `workloads/missing_index_todos/oracle.rb`
- Modify: `workloads/missing_index_todos/test/oracle_test.rb`

- [ ] **Step 1: Write failing oracle tests for the `total_exec_time` dominance margin**

```ruby
def test_oracle_passes_when_primary_query_dominates_by_three_x
  oracle = build_oracle(clickhouse_rows: [
    {"queryid" => "primary", "total_exec_time_ms" => "900.0"},
    {"queryid" => "other", "total_exec_time_ms" => "250.0"}
  ])

  result = oracle.call

  assert_includes result.fetch(:messages), /dominance/
end

def test_oracle_fails_when_primary_query_loses_dominance_margin
  oracle = build_oracle(clickhouse_rows: [
    {"queryid" => "primary", "total_exec_time_ms" => "900.0"},
    {"queryid" => "other", "total_exec_time_ms" => "400.0"}
  ])

  error = assert_raises(RuntimeError) { oracle.call }
  assert_includes error.message, "3x"
end
```

- [ ] **Step 2: Run the oracle tests to verify they fail**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby workloads/missing_index_todos/test/oracle_test.rb`

Expected: FAIL because the oracle does not assert the dominance margin yet.

- [ ] **Step 3: Implement the minimal dominance check**

```ruby
def assert_dominance(rows)
  primary = rows.find { |row| row.fetch("queryid") == expected_queryid }
  challenger = rows.reject { |row| row.fetch("queryid") == expected_queryid }.max_by { |row| row.fetch("total_exec_time_ms").to_f }
  return if challenger.nil?

  primary_time = primary.fetch("total_exec_time_ms").to_f
  challenger_time = challenger.fetch("total_exec_time_ms").to_f
  raise "dominance margin failed: #{primary_time} < 3x #{challenger_time}" unless primary_time >= (challenger_time * 3.0)
end
```

- [ ] **Step 4: Run the oracle tests to verify they pass**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby workloads/missing_index_todos/test/oracle_test.rb`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add workloads/missing_index_todos/oracle.rb workloads/missing_index_todos/test/oracle_test.rb
git commit -m "feat: assert missing-index dominance margin"
```

## Task 10: Wire The Demo App CI To `verify-fixture`

**Files:**
- Modify: `/home/bjw/db-specialist-demo` CI file(s)
- Modify: `/home/bjw/db-specialist-demo/README.md` or developer docs if the repo has a benchmark-check section

- [ ] **Step 1: Write the failing CI hook change**

Add a job step that shells out to the local collector checkout:

```bash
CHECKPOINT_COLLECTOR_PATH=${CHECKPOINT_COLLECTOR_PATH:-/home/bjw/checkpoint-collector}

DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo \
BENCH_ADAPTER_PG_ADMIN_URL=postgres://postgres:postgres@localhost:5432/postgres \
BUNDLE_GEMFILE="$CHECKPOINT_COLLECTOR_PATH/collector/Gemfile" \
"$CHECKPOINT_COLLECTOR_PATH/bin/load" verify-fixture \
  --workload missing-index-todos \
  --adapter "$CHECKPOINT_COLLECTOR_PATH/adapters/rails/bin/bench-adapter" \
  --app-root "$PWD"
```

- [ ] **Step 2: Run the CI-equivalent command locally to verify it fails before the hook is complete**

Run:

```bash
CHECKPOINT_COLLECTOR_PATH=/home/bjw/checkpoint-collector \
DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo \
BENCH_ADAPTER_PG_ADMIN_URL=postgres://postgres:postgres@localhost:5432/postgres \
BUNDLE_GEMFILE=/home/bjw/checkpoint-collector/collector/Gemfile \
/home/bjw/checkpoint-collector/bin/load verify-fixture \
  --workload missing-index-todos \
  --adapter /home/bjw/checkpoint-collector/adapters/rails/bin/bench-adapter \
  --app-root /home/bjw/db-specialist-demo
```

Expected: FAIL until the app pathologies and verifier are both implemented.

- [ ] **Step 3: Implement the CI hook minimally**

Update the demo app workflow/job definition to run the exact command above after the benchmark DB is available.

- [ ] **Step 4: Re-run the CI-equivalent command to verify it passes**

Run the same command from Step 2 after Tasks 3-9 are complete.

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git -C /home/bjw/db-specialist-demo add .github/workflows README.md
git -C /home/bjw/db-specialist-demo commit -m "test: require fixture verification"
```

## Task 11: Refresh The Operator Surface

**Files:**
- Modify: `README.md`
- Modify: `Makefile`
- Modify: `load/test/load_smoke_target_test.rb`
- Create: `load/test/soak_target_test.rb` if the smoke-target test is already too broad
- Modify: `JOURNAL.md`

- [ ] **Step 1: Write failing tests for the new operator commands**

```ruby
def test_makefile_exposes_verify_fixture_and_soak_targets
  makefile = File.read(File.expand_path("../../Makefile", __dir__))

  assert_includes makefile, "verify-fixture:"
  assert_includes makefile, "load-soak:"
end

def test_readme_documents_soak_and_verify_fixture
  readme = File.read(File.expand_path("../../README.md", __dir__))

  assert_includes readme, "bin/load verify-fixture"
  assert_includes readme, "bin/load soak"
end
```

- [ ] **Step 2: Run the docs/Makefile tests to verify they fail**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/load_smoke_target_test.rb`

Expected: FAIL because the targets/docs do not exist yet.

- [ ] **Step 3: Implement the minimal README/Makefile updates**

```make
verify-fixture:
	DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo \
	BENCH_ADAPTER_PG_ADMIN_URL=postgres://postgres:postgres@localhost:5432/postgres \
	BUNDLE_GEMFILE=collector/Gemfile \
	bin/load verify-fixture --workload missing-index-todos --adapter adapters/rails/bin/bench-adapter --app-root /home/bjw/db-specialist-demo

load-soak:
	DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo \
	BENCH_ADAPTER_PG_ADMIN_URL=postgres://postgres:postgres@localhost:5432/postgres \
	BUNDLE_GEMFILE=collector/Gemfile \
	bin/load soak --workload missing-index-todos --adapter adapters/rails/bin/bench-adapter --app-root /home/bjw/db-specialist-demo
```

- [ ] **Step 4: Run the docs/Makefile tests to verify they pass**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/load_smoke_target_test.rb`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add README.md Makefile load/test/load_smoke_target_test.rb load/test/soak_target_test.rb JOURNAL.md
git commit -m "docs: add mixed fixture operator workflow"
```

## Task 12: End-To-End Verification

**Files:**
- No code changes required unless verification exposes a real bug

- [ ] **Step 1: Run the checkpoint-collector suites**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby -e 'Dir["load/test/*_test.rb"].sort.each { |path| load path }'
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby -e 'Dir["workloads/missing_index_todos/test/*_test.rb"].sort.each { |path| load path }'
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby -e 'Dir["adapters/rails/test/*_test.rb"].sort.each { |path| load path }'
```

Expected: PASS, with only the existing intentional adapter integration skips unless explicitly enabled.

- [ ] **Step 2: Run the demo-app suite**

Run:

```bash
cd /home/bjw/db-specialist-demo
BUNDLE_USER_HOME=/tmp/bundle BUNDLE_PATH=vendor/bundle bundle exec rails test
```

Expected: PASS

- [ ] **Step 3: Run `verify-fixture` manually**

Run:

```bash
DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo \
BENCH_ADAPTER_PG_ADMIN_URL=postgres://postgres:postgres@localhost:5432/postgres \
BUNDLE_GEMFILE=collector/Gemfile \
bin/load verify-fixture \
  --workload missing-index-todos \
  --adapter adapters/rails/bin/bench-adapter \
  --app-root /home/bjw/db-specialist-demo
```

Expected: PASS with all three checks reported.

- [ ] **Step 4: Run a finite benchmark and the oracle**

Run:

```bash
DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo \
BENCH_ADAPTER_PG_ADMIN_URL=postgres://postgres:postgres@localhost:5432/postgres \
BUNDLE_GEMFILE=collector/Gemfile \
bin/load run \
  --workload missing-index-todos \
  --adapter adapters/rails/bin/bench-adapter \
  --app-root /home/bjw/db-specialist-demo

latest=$(ls -1dt runs/* | head -n1)
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby workloads/missing_index_todos/oracle.rb "$latest"
```

Expected: PASS for explain, ClickHouse, and dominance margin.

- [ ] **Step 5: Run a soak session and confirm clean stop**

Run:

```bash
DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo \
BENCH_ADAPTER_PG_ADMIN_URL=postgres://postgres:postgres@localhost:5432/postgres \
BUNDLE_GEMFILE=collector/Gemfile \
timeout 90 bin/load soak \
  --workload missing-index-todos \
  --adapter adapters/rails/bin/bench-adapter \
  --app-root /home/bjw/db-specialist-demo
```

Expected: exits non-zero only if the `timeout` wrapper kills it; otherwise, if interrupted manually, the run record should include invariant samples and either a clean abort or an intentional invariant-breach stop if the dataset drifted.

- [ ] **Step 6: Commit any verification-only adjustments**

```bash
git add <only files changed by real bug fixes>
git commit -m "fix: address mixed fixture verification gaps"
```

## Spec Coverage Check

- JSON API routes and bounded delete: Tasks 3-5
- Preserving three pathologies: Tasks 4 and 6
- Dataset size and seed tuning: Task 5
- Mixed workload and dominance target: Tasks 2 and 9
- Finite and soak modes: Tasks 1, 7, and 8
- Soak invariant sampling and abort rules: Task 8
- `verify-fixture` pre-flight gate: Tasks 6, 7, and 10
- Demo-app CI wiring to `checkpoint-collector/bin/load verify-fixture`: Task 10
- README/Makefile/operator workflow: Task 11
- End-to-end verification: Task 12

## Placeholder Scan

- No `TODO`/`TBD` placeholders remain.
- Every task names exact files and commands.
- Every code-changing task includes example test and implementation snippets.

## Type Consistency Check

- Command names are consistently `run`, `soak`, and `verify-fixture`.
- Workload name stays `missing-index-todos` throughout.
- Primary guard stays “dominance by `total_exec_time` ≥ 3× next queryid”.
- Secondary protections stay “verify-fixture” smoke, not oracle expansion.
