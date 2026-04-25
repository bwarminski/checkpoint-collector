# Mixed Missing-Index Todo Fixture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

## Revision History

**2026-04-24 — Round 1 plan-eng-review (DO_NOT_SHIP → revised)**

Eight findings folded back into the plan. Each delta is sited in the task it touches; the implementor should treat the revised text as authoritative.

| Finding | Where applied |
|---|---|
| F1 — Pre-flight gate must run after `:start`, not before (verifier needs HTTP endpoints) | Task 7 architectural note + revised tests + revised pseudo-impl |
| F2 — Counts smoke must check call counts ≥ users_count, not just ≥2 distinct queryids | Task 4 demo-app pathology test + Task 6 verifier impl + tests |
| F3 — Sustained-breach semantics simplified to 3 consecutive sample breaches (≈3 min) | Task 8 alignment note + tests; spec §7.2 updated to match |
| F4 — Oracle dominance needs a new top-N ClickHouse SQL, not just new test fixtures | Task 9 SQL spec + revised tests + impl + integration with existing oracle |
| F5 — `Load::CLI#default_runner` must be extended to wire `Load::FixtureVerifier` and accept `mode:` | Task 1 Step 3.5 + non-mocked smoke test |
| F6 — Soak-mode test replaces `sleep 0.1` with a `Queue` synchronization barrier | Task 8 revised soak tests |
| F7 — Invariant sampler runs on isolated PG connection with `pg_stat_statements.track = 'none'` | Task 8 sampler isolation note + impl + dedicated test |
| F8 — `db-specialist-demo` schema must be verified, with migrations added if needed | Task 3 Step 0 |
| F9 — Workload weights must sum to 100 and be locked exactly in tests | Task 2 weights table + revised test |
| F10 — Task 3 `index` action: drop dead `"nil"` literal | Task 3 controller pseudo-impl |
| F12 — Add tuning contingency if dominance margin fails on first real run | Task 12 Step 4 |

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

- [ ] **Step 3.5: Update `default_runner` and add `default_verifier_factory` (production wiring)**

The new `runner_factory` and `verifier_factory` injection points are tested via mocks in Step 1, but `Load::CLI`'s production defaults must also construct real instances. Without this, `bin/load run` and `bin/load verify-fixture` outside tests will not have a verifier wired in.

Update `cli.rb`:

```ruby
def initialize(argv:, version:, runner_factory: nil, verifier_factory: nil, stop_flag: nil, stdout: $stdout, stderr: $stderr)
  @runner_factory = runner_factory || method(:default_runner_factory)
  @verifier_factory = verifier_factory || method(:default_verifier_factory)
  ...
end

def default_runner_factory(workload:, mode:, adapter_bin:, app_root:, ...)
  ...
  Load::Runner.new(workload:, adapter_client:, run_record:, mode:, verifier: @verifier_factory.call(workload_name: workload.name, adapter_client:, app_root:), ...)
end

def default_verifier_factory(workload_name:, adapter_client:, app_root:, **)
  Load::FixtureVerifier.new(workload_name: workload_name, adapter_client: adapter_client, app_root: app_root)
end
```

Add a non-mocked smoke test that exercises `default_runner_factory` end-to-end at the unit level (runner construction succeeds; verifier present; mode propagated):

```ruby
def test_default_runner_factory_constructs_runner_with_verifier_and_mode
  cli = Load::CLI.new(argv: ["run", "--workload", "missing-index-todos", "--adapter", "/tmp/adapter", "--app-root", "/tmp/demo"], version: "0.3.0")
  options = cli.send(:parse_options)
  runner = cli.send(:default_runner_factory, workload: stub_workload, mode: :finite, **options)
  refute_nil runner.instance_variable_get(:@verifier)
  assert_equal :finite, runner.mode
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
  weights = workload.actions.map(&:weight)

  assert_equal %w[ListOpenTodos ListRecentTodos CreateTodo CloseTodo DeleteCompletedTodos FetchCounts SearchTodos], names
  assert_equal [65, 12, 7, 7, 3, 4, 2], weights
  assert_equal 100, weights.sum, "weights must sum to 100 to match spec §6.1 percentages"
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
    Load::ActionEntry.new(Actions::ListOpenTodos, 65),       # 65% — primary pathology, must dominate
    Load::ActionEntry.new(Actions::ListRecentTodos, 12),     # 12% — paginated indexed read
    Load::ActionEntry.new(Actions::CreateTodo, 7),           # 7%  — open replenishment
    Load::ActionEntry.new(Actions::CloseTodo, 7),            # 7%  — open drain (balances create)
    Load::ActionEntry.new(Actions::DeleteCompletedTodos, 3), # 3%  — bounded per §5.2.1
    Load::ActionEntry.new(Actions::FetchCounts, 4),          # 4%  — secondary N+1 pathology
    Load::ActionEntry.new(Actions::SearchTodos, 2)           # 2%  — secondary rewrite_like pathology
  ]                                                          # ───
end                                                          # 100
```

Weights sum to exactly 100 to match the spec §6.1 percentage framing. The `Load::Selector` normalizes regardless, but locking to 100 keeps the test, the spec, and any future operator-readable run record consistent.

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
- Inspect: `/home/bjw/db-specialist-demo/db/schema.rb`
- Create (if needed): `/home/bjw/db-specialist-demo/db/migrate/<timestamp>_extend_todos_for_mixed_workload.rb`
- Modify: `/home/bjw/db-specialist-demo/config/routes.rb`
- Modify: `/home/bjw/db-specialist-demo/app/controllers/todos_controller.rb`
- Modify: `/home/bjw/db-specialist-demo/app/models/todo.rb`
- Modify: `/home/bjw/db-specialist-demo/app/models/user.rb`
- Modify: `/home/bjw/db-specialist-demo/test/controllers/todos_controller_test.rb`

- [ ] **Step 0: Verify the existing schema and add migrations only if gaps exist**

Read `/home/bjw/db-specialist-demo/db/schema.rb` and confirm the following invariants hold; if any are missing, add a migration to fix it. The pathology contract requires:

- `users` table exists (id, plus whatever the demo app already uses)
- `todos` columns: `id`, `user_id` (FK to users), `status` (string), `title` (string), `created_at`
- index on `todos(user_id)` exists
- **NO index on `todos(status)`** — this is the primary pathology; if one exists, the migration must drop it (and the migration must be a separate commit so the drop is auditable)

If migrations are needed, capture them as their own commit before the controller work:

```bash
cd /home/bjw/db-specialist-demo
bin/rails generate migration ExtendTodosForMixedWorkload
# edit the migration file
bin/rails db:migrate
git add db/migrate db/schema.rb
git commit -m "chore: align todos schema for mixed workload"
```

If the schema already matches, log the verification in the implementor notes and proceed.

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
  scope = scope.where(status: params[:status]) if params[:status].present? && params[:status] != "all"
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

The N+1 pathology test is the load-bearing one for §5.3 — it locks the actual broken behavior, not just the JSON shape. Same for the search query plan.

```ruby
test "counts returns per-user totals" do
  get "/api/todos/counts"
  assert_response :success
  body = JSON.parse(@response.body)
  assert body.key?(users(:one).id.to_s)
end

test "counts issues N+1 against todos (pathology contract)" do
  ActiveRecord::Base.connection.execute("SELECT pg_stat_statements_reset()")
  expected_users = User.count
  get "/api/todos/counts"
  assert_response :success

  count_subquery_calls = ActiveRecord::Base.connection.exec_query(<<~SQL).rows.flatten.first.to_i
    SELECT COALESCE(SUM(calls), 0) FROM pg_stat_statements
    WHERE query LIKE '%FROM "todos"%' AND query LIKE '%user_id%'
  SQL
  assert_operator count_subquery_calls, :>=, expected_users,
    "expected /counts to issue at least one COUNT(*) per user (N+1 pathology); saw #{count_subquery_calls} calls for #{expected_users} users"
end

test "search returns matching todos" do
  get "/api/todos/search", params: {q: "alpha"}
  assert_response :success
  body = JSON.parse(@response.body)
  assert body.fetch("items").all? { |item| item.fetch("title").include?("alpha") }
end

test "search uses sequential scan with LIKE filter (rewrite_like pathology contract)" do
  plan = ActiveRecord::Base.connection.exec_query(
    "EXPLAIN (FORMAT JSON) SELECT * FROM todos WHERE title LIKE '%foo%' ORDER BY created_at DESC LIMIT 50"
  ).rows.flatten.first
  parsed = JSON.parse(plan).first.fetch("Plan")
  assert_match(/Seq Scan/, parsed.fetch("Node Type") + (parsed["Plans"]&.map { |p| p["Node Type"] }&.join(",") || ""))
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

The counts check must use **call counts**, not just queryid count. A "fix" that consolidates the N+1 to a single `GROUP BY` query still produces 2 distinct queryids (one for `User.all`, one for the GROUP BY). The smoke must verify call growth proportional to `users_count`.

```ruby
def test_verify_fixture_checks_missing_index_counts_and_search
  verifier = Load::FixtureVerifier.new(
    workload_name: "missing-index-todos",
    adapter_client: fake_adapter_client,
    explain_reader: fake_explain_reader(
      open_plan: seq_scan_plan("status"),
      search_plan: search_reference_plan
    ),
    stats_reader: fake_stats_reader(
      counts_subquery_calls: 11,   # >= users_count + 1, given fake users_count = 10
      counts_users_count: 10
    )
  )

  result = verifier.call

  assert_equal true, result.fetch(:ok)
  assert_equal %w[missing_index counts_n_plus_one search_rewrite], result.fetch(:checks).map { |check| check.fetch(:name) }
end

def test_verify_fixture_fails_when_counts_consolidates_to_one_query
  # GROUP BY "fix" produces 2 queryids but only 2 total calls — far below users_count.
  verifier = Load::FixtureVerifier.new(
    workload_name: "missing-index-todos",
    adapter_client: fake_adapter_client,
    explain_reader: fake_explain_reader(open_plan: seq_scan_plan("status"), search_plan: search_reference_plan),
    stats_reader: fake_stats_reader(counts_subquery_calls: 2, counts_users_count: 10)
  )

  error = assert_raises(Load::FixtureVerifier::VerificationError) { verifier.call }
  assert_includes error.message, "/api/todos/counts"
  assert_includes error.message, "10 users"  # the failure must name what it expected
end

def test_verify_fixture_fails_when_seq_scan_is_replaced_by_index
  verifier = Load::FixtureVerifier.new(
    workload_name: "missing-index-todos",
    adapter_client: fake_adapter_client,
    explain_reader: fake_explain_reader(open_plan: index_scan_plan("status"), search_plan: search_reference_plan),
    stats_reader: fake_stats_reader(counts_subquery_calls: 11, counts_users_count: 10)
  )
  error = assert_raises(Load::FixtureVerifier::VerificationError) { verifier.call }
  assert_includes error.message, "Seq Scan"
end

def test_verify_fixture_fails_when_search_plan_drifts_from_reference
  verifier = Load::FixtureVerifier.new(
    workload_name: "missing-index-todos",
    adapter_client: fake_adapter_client,
    explain_reader: fake_explain_reader(open_plan: seq_scan_plan("status"), search_plan: trigram_index_plan),
    stats_reader: fake_stats_reader(counts_subquery_calls: 11, counts_users_count: 10)
  )
  error = assert_raises(Load::FixtureVerifier::VerificationError) { verifier.call }
  assert_includes error.message, "search"
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
  response = client.get("/api/todos/counts")
  users_count = JSON.parse(response.body).keys.length
  subquery_calls = stats_reader.subquery_calls_for(table: "todos", filter_columns: ["user_id"])
  unless subquery_calls >= users_count
    raise VerificationError,
      "counts pathology missing for /api/todos/counts: expected at least #{users_count} subquery calls (one per user), saw #{subquery_calls}"
  end
  {name: "counts_n_plus_one", ok: true, calls: subquery_calls, users: users_count}
end
```

The check uses `users_count` derived from the response body (which is `{user_id => count}`) so it auto-scales with the demo-app dataset. `stats_reader.subquery_calls_for` does:

```sql
SELECT COALESCE(SUM(calls), 0)
  FROM pg_stat_statements
 WHERE query LIKE '%FROM "todos"%' AND query LIKE '%user_id%'
```

run against the post-call stats snapshot. This catches both the "removed N+1 entirely" failure mode and the "GROUP BY fix" failure mode, because the GROUP BY fix produces a query without `user_id` in the WHERE clause.

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

**Architectural note (load-bearing):** the verifier issues real HTTP requests against the app-under-test (`GET /api/todos?status=open`, `/counts`, `/search`), so it MUST run **after** `start` returns and the readiness gate passes — otherwise the endpoints don't exist. The gate runs **before** workers begin, so a verifier failure aborts cleanly without any benchmark traffic. The cleanup path still calls `:stop` to shut down the adapter app.

Run order:

```
describe → prepare → reset_state → start → readiness → verify → workers → stop
                                            (gate fires here ───┘)
```

- [ ] **Step 1: Write failing runner tests for pre-flight gating**

```ruby
def test_runner_calls_verify_fixture_after_start_and_before_workers
  verifier = Minitest::Mock.new
  verifier.expect(:call, {ok: true})
  adapter = fake_adapter_client
  worker_factory = ->(**kwargs) { @workers_constructed = true; fake_worker }

  runner = build_runner(mode: :finite, adapter_client: adapter, verifier: verifier, worker_factory: worker_factory)
  runner.run

  verifier.verify
  assert_equal [:describe, :prepare, :reset_state, :start, :stop], adapter.calls
  # Verifier was called with the live base_url from start (proves ordering)
  assert_includes verifier.call_args.last, base_url: adapter.start_response.fetch("base_url")
end

def test_runner_aborts_after_start_before_workers_when_verify_fixture_fails
  workers_constructed = false
  worker_factory = ->(**kwargs) { workers_constructed = true; fake_worker }
  failing_verifier = ->(**) { raise Load::FixtureVerifier::VerificationError, "counts pathology missing" }
  adapter = fake_adapter_client

  runner = build_runner(mode: :finite, adapter_client: adapter, verifier: failing_verifier, worker_factory: worker_factory)

  assert_equal Load::ExitCodes::ERROR, runner.run
  refute workers_constructed, "workers must not be constructed when verify-fixture fails"
  assert_equal [:describe, :prepare, :reset_state, :start, :stop], adapter.calls,
    "adapter must still be stopped cleanly after verifier failure"
  refute File.exist?(File.join(runner.run_record.run_dir, "metrics.jsonl"))
  assert_equal "fixture_verification_failed", runner.run_record.read_run_json.dig("outcome", "error_code")
end
```

- [ ] **Step 2: Run the runner tests to verify they fail**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb`

Expected: FAIL because the runner does not invoke `verify-fixture` yet.

- [ ] **Step 3: Implement the minimal pre-flight gate**

```ruby
def run
  result = Load::ExitCodes::OK
  begin
    @run_record.write_run(snapshot_state)
    boot_adapter           # describe → prepare → reset_state → start → readiness
    verifier.call(base_url: adapter_state.fetch(:base_url))
    start_workers(adapter_state.fetch(:base_url))
    result = finish_run
  rescue Load::FixtureVerifier::VerificationError => error
    write_state(outcome: outcome_payload(aborted: true, error_code: "fixture_verification_failed", error_message: error.message))
    result = Load::ExitCodes::ERROR
  rescue AdapterClient::AdapterError
    ...
  ensure
    result = stop_adapter_safely(result)
  end
  result
end
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

**Spec alignment note:** the abort threshold is **3 consecutive sample breaches** (≈3 minutes at the 60s sampling cadence). This is a deliberate simplification of spec §7.2's earlier "3 sustained breaches of 5 samples each" wording — the simpler semantics catches dataset drift fast enough for the agent-exercise use case and is easier to test. Spec §7.2 will be updated to match before merge.

**Sampler isolation note:** the invariant sampler runs `SELECT COUNT(*) FROM todos WHERE status='open'` on the same database the workload hits. Without isolation, those samples land in `pg_stat_statements` and inflate the dominance signal that the §8 oracle reads — the sampler's count query has the same shape as the workload's list-open query. The sampler must run on a dedicated PG connection with `SET LOCAL pg_stat_statements.track = 'none'` so the samples are invisible to oracle attribution. Use `pg_class.reltuples::bigint` for the cheap `total_count` approximation; reserve the actual `COUNT(*)` for `open_count` only.

- [ ] **Step 1: Write failing tests for continuous mode and invariant breaches**

The soak-mode test uses an explicit synchronization barrier instead of `sleep` to avoid timing flakes (real `sleep`-based sync was the v0.3.0.0 ship-review failure mode). The breach-abort test exercises the 3-consecutive-sample threshold; a separate test asserts a single breach followed by recovery does not abort.

```ruby
def test_soak_mode_runs_until_stop_flag
  stop_flag = Load::Runner::InternalStopFlag.new
  workers_ready = Queue.new
  worker_factory = ->(**kwargs) { FakeWorker.new(on_run: -> { workers_ready << :ready; sleep until stop_flag.call }) }

  runner = build_runner(mode: :continuous, stop_flag: stop_flag, worker_factory: worker_factory)
  thread = Thread.new { runner.run }

  workers_ready.pop  # blocks until a worker actually started — no sleep, no race
  stop_flag.trigger(:sigterm)

  assert_equal Load::ExitCodes::ABORTED, thread.value
  assert thread.join(2.0), "runner did not exit within 2s of stop signal"
end

def test_runner_aborts_after_three_consecutive_invariant_breaches
  sampler = fake_sampler([
    {open_count: 100,    total_count: 10_000},  # below open_floor (default 30k) — breach #1
    {open_count: 100,    total_count: 10_000},  # breach #2
    {open_count: 100,    total_count: 10_000}   # breach #3 → abort
  ])

  runner = build_runner(mode: :continuous, invariant_sampler: sampler)
  assert_equal Load::ExitCodes::ERROR, runner.run

  warnings = runner.run_record.read_run_json.fetch("warnings")
  assert_equal 3, warnings.length
  assert_includes warnings.last.fetch("message"), "open_count"
  assert_equal "invariant_breach", runner.run_record.read_run_json.dig("outcome", "error_code")
end

def test_runner_does_not_abort_when_breach_recovers
  # breach → recover → healthy: the consecutive-breach counter must reset on recovery.
  sampler = fake_sampler([
    {open_count: 100,    total_count: 10_000},  # breach
    {open_count: 100,    total_count: 10_000},  # breach
    {open_count: 35_000, total_count: 100_000}, # healthy — counter resets
    {open_count: 100,    total_count: 10_000},  # breach (only #1 of new run)
    {open_count: 35_000, total_count: 100_000}  # healthy
  ])
  stop_flag = Load::Runner::InternalStopFlag.new
  runner = build_runner(mode: :continuous, invariant_sampler: sampler, stop_flag: stop_flag)
  thread = Thread.new { runner.run }
  # consume the 5 samples then stop cleanly
  sampler.wait_until_drained
  stop_flag.trigger(:sigterm)

  assert_equal Load::ExitCodes::ABORTED, thread.value
  assert_equal 3, runner.run_record.read_run_json.fetch("warnings").length
end

def test_invariant_sampler_uses_isolated_pg_connection
  pg_pool = FakePgPool.new
  sampler = Load::Runner::InvariantSampler.new(pg: pg_pool, ...)
  sampler.call

  refute pg_pool.shared_connection_used?, "sampler must not reuse the workload's pg_stat_statements-tracked connection"
  assert_includes pg_pool.last_connection_session_settings, "pg_stat_statements.track = 'none'"
end
```

- [ ] **Step 2: Run the runner/run-record tests to verify they fail**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb && BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/run_record_test.rb`

Expected: FAIL because continuous mode, the recovery counter, sampler isolation, and warning persistence do not exist yet.

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
  if sample.breach?
    run_record.append_warning(sample.to_h)
    @consecutive_breaches += 1
    trigger_stop(:invariant_breach) if @consecutive_breaches >= 3
  else
    @consecutive_breaches = 0  # reset on recovery
  end
end
```

```ruby
class InvariantSampler
  def initialize(pg:, database_url:, open_floor:, total_floor:, total_ceiling:)
    @pg = pg
    @database_url = database_url
    @open_floor = open_floor
    @total_floor = total_floor
    @total_ceiling = total_ceiling
  end

  def call
    @pg.with_isolated_connection(@database_url) do |conn|
      conn.exec("SET LOCAL pg_stat_statements.track = 'none'")
      open_count  = conn.exec("SELECT COUNT(*) FROM todos WHERE status = 'open'").first.fetch("count").to_i
      total_count = conn.exec("SELECT reltuples::bigint AS count FROM pg_class WHERE relname = 'todos'").first.fetch("count").to_i
      Sample.new(open_count: open_count, total_count: total_count, open_floor: @open_floor, total_floor: @total_floor, total_ceiling: @total_ceiling)
    end
  end
end
```

`with_isolated_connection` opens a dedicated PG connection (not pooled with the workload) so the `SET LOCAL pg_stat_statements.track = 'none'` scope cannot leak back to the workload session.

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

**ClickHouse SQL note:** the existing oracle (`oracle.rb:190-201`) issues a single-row aggregation with `WHERE queryid IN (...)`. The dominance check needs a **second, distinct** ClickHouse query that returns top-N queryids over the run window, no `WHERE queryid IN` constraint, ranked by total exec time. The existing single-row query for the primary's call count is preserved as-is — these are two separate reads of `query_intervals`.

The new SQL (run alongside, not replacing, the existing one):

```sql
SELECT
  toString(queryid) AS queryid,
  toString(sum(total_exec_count)) AS total_calls,
  toString(round(sum(total_exec_count * avg_exec_time_ms), 1)) AS total_exec_time_ms_estimate
FROM query_intervals
WHERE interval_ended_at BETWEEN parseDateTime64BestEffort('<window.start_ts>')
                            AND parseDateTime64BestEffort('<window.end_ts>') + INTERVAL 90 SECOND
GROUP BY queryid
ORDER BY sum(total_exec_count * avg_exec_time_ms) DESC
LIMIT 10
FORMAT JSONEachRow
```

`total_exec_time_ms_estimate = sum(total_exec_count × avg_exec_time_ms)` is the per-queryid total DB time over the window. ClickHouse `query_intervals` exposes `total_exec_count` and `avg_exec_time_ms` per interval but does not store `total_exec_time` directly — the multiplication is the canonical reconstruction.

The dominance check then iterates the top-N rows: the **primary** is the first row whose queryid is in `expected_queryids` (the one(s) captured during reset-state); the **challenger** is the highest-scoring row whose queryid is **not** in `expected_queryids`. Sampler queryids cannot pollute this because Task 8 isolates them on a `pg_stat_statements.track = 'none'` connection (F7).

- [ ] **Step 1: Write failing oracle tests for the `total_exec_time` dominance margin**

```ruby
def test_oracle_passes_when_primary_query_dominates_by_three_x
  oracle = build_oracle(
    expected_queryids: ["primary"],
    clickhouse_topn_rows: [
      {"queryid" => "primary", "total_calls" => "70000", "total_exec_time_ms_estimate" => "900.0"},
      {"queryid" => "other",   "total_calls" => "5000",  "total_exec_time_ms_estimate" => "250.0"}
    ]
  )

  result = oracle.call

  assert_includes result.fetch(:messages).join("\n"), "dominance"
  assert_match(/3\.6x/, result.fetch(:messages).join("\n"))
end

def test_oracle_fails_when_primary_query_loses_dominance_margin
  oracle = build_oracle(
    expected_queryids: ["primary"],
    clickhouse_topn_rows: [
      {"queryid" => "primary", "total_calls" => "70000", "total_exec_time_ms_estimate" => "900.0"},
      {"queryid" => "other",   "total_calls" => "5000",  "total_exec_time_ms_estimate" => "400.0"}
    ]
  )

  error = assert_raises(Load::Workloads::MissingIndexTodos::Oracle::Failure) { oracle.call }
  assert_includes error.message, "3x"
  assert_match(/2\.25x/, error.message)
end

def test_oracle_dominance_passes_when_no_challenger
  # Single queryid in pg_stat_statements / clickhouse — primary trivially dominates.
  oracle = build_oracle(
    expected_queryids: ["primary"],
    clickhouse_topn_rows: [
      {"queryid" => "primary", "total_calls" => "70000", "total_exec_time_ms_estimate" => "900.0"}
    ]
  )

  result = oracle.call
  assert_includes result.fetch(:messages).join("\n"), "no challenger"
end
```

- [ ] **Step 2: Run the oracle tests to verify they fail**

Run: `BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby workloads/missing_index_todos/test/oracle_test.rb`

Expected: FAIL because the oracle does not issue the top-N query or assert the dominance margin yet.

- [ ] **Step 3: Implement the minimal dominance check**

```ruby
def assert_dominance(window:, expected_queryids:, clickhouse_url:)
  rows = @clickhouse_query.call(:topn, window: window, clickhouse_url: clickhouse_url)
  primary = rows.find { |row| expected_queryids.include?(row.fetch("queryid")) }
  raise Failure, "FAIL: dominance (primary queryid not present in top-N)" if primary.nil?

  challenger = rows.find { |row| !expected_queryids.include?(row.fetch("queryid")) }
  if challenger.nil?
    @stdout.puts("PASS: dominance (no challenger; primary stands alone)")
    return
  end

  primary_time    = primary.fetch("total_exec_time_ms_estimate").to_f
  challenger_time = challenger.fetch("total_exec_time_ms_estimate").to_f
  ratio           = primary_time / challenger_time

  if primary_time >= challenger_time * 3.0
    @stdout.puts("PASS: dominance (#{ratio.round(2)}x over next queryid)")
  else
    raise Failure, "FAIL: dominance (#{primary_time}ms / #{challenger_time}ms = #{ratio.round(2)}x; required: ≥3x)"
  end
end
```

The oracle's existing `wait_for_clickhouse!` path stays in place for the primary's call-threshold check; `assert_dominance` is a separate, additive call sited after it.

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

**If dominance fails on the first real run** (margin < 3×): treat this as a *tuning gap*, not a bug. The likely causes, in order:

1. The dataset is smaller than spec §5.4 targets (`ROWS_PER_TABLE=100000`, `OPEN_FRACTION=0.6`). Inspect run record + `pg_class.reltuples`, re-seed if smaller, re-run.
2. The `FetchCounts` or `SearchTodos` action is more expensive in the real demo app than the cost-model assumed. Inspect the top-N rows from the dominance query — if a non-primary queryid is unexpectedly high, that's the culprit. Reduce its weight (e.g., counts 4→3, search 2→1) and bump `ListOpenTodos` accordingly while keeping the sum at 100.
3. The seq-scan is too cheap because `OPEN_FRACTION` produces too few matching rows. Bump `OPEN_FRACTION` toward 0.6 if it's been overridden lower.

After any tuning change, re-run Steps 3-4 to confirm the change holds. Do not claim Task 12 complete with dominance below 3×.

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
