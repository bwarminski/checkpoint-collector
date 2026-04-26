# Tenant-Shaped Missing-Index Workload Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reshape `missing-index-todos` into a tenant-scoped workload and move verifier ownership fully into the workload without changing the primary oracle contract.

**Architecture:** Keep the core load library orchestration generic while moving todo-specific verification into `workloads/missing_index_todos/`. At the same time, make the demo app and workload actions tenant-shaped by reading `USER_COUNT` from `Load::Scale#extra` and scoping list/search/write traffic to one user.

**Tech Stack:** Ruby, Minitest, Rails JSON API in `~/db-specialist-demo`, existing load runner/oracle infrastructure.

---

## File Map

- Modify: `workloads/missing_index_todos/workload.rb`
  - Add `USER_COUNT` to workload scale extras and wire the workload-owned verifier.
- Create: `workloads/missing_index_todos/verifier.rb`
  - Own all `missing-index-todos` fixture verification logic.
- Modify: `workloads/missing_index_todos/actions/list_open_todos.rb`
  - Make request user-scoped.
- Modify: `workloads/missing_index_todos/actions/list_recent_todos.rb`
  - Make request user-scoped.
- Modify: `workloads/missing_index_todos/actions/search_todos.rb`
  - Make request user-scoped.
- Modify: `workloads/missing_index_todos/actions/create_todo.rb`
  - Sample `user_id` from `USER_COUNT` rather than todo volume.
- Modify: `workloads/missing_index_todos/actions/close_todo.rb`
  - Fetch one user’s open todos before choosing a close target.
- Modify: `workloads/missing_index_todos/actions/delete_completed_todos.rb`
  - Make delete request direct and user-scoped.
- Modify: `workloads/missing_index_todos/test/*`
  - Update workload/action tests and add verifier coverage.
- Modify: `load/lib/load/cli.rb`
  - Remove any remaining todo-specific verifier assumptions.
- Modify: `load/lib/load/workload.rb`
  - Keep only the generic verifier hook contract.
- Delete or modify heavily: `load/lib/load/fixture_verifier.rb`
  - Remove todo-specific verification ownership from core load code.
- Modify: `load/test/cli_test.rb`
  - Lock workload-owned verifier wiring.
- Modify: `~/db-specialist-demo/db/seeds.rb`
  - Read `USER_COUNT` and seed a tenant-shaped dataset.
- Modify: `~/db-specialist-demo/config/routes.rb`
  - Express user-scoped JSON routes clearly.
- Modify: `~/db-specialist-demo/app/controllers/...`
  - Scope list/search/delete behavior by `user_id`.
- Modify: `~/db-specialist-demo/test/...`
  - Add/update controller/model tests for the tenant-shaped API.
- Modify: `JOURNAL.md`
  - Record any non-obvious decisions or verification findings.

## Task 1: Make the Workload Scale and Actions Tenant-Shaped

**Files:**
- Modify: `workloads/missing_index_todos/workload.rb`
- Modify: `workloads/missing_index_todos/actions/list_open_todos.rb`
- Modify: `workloads/missing_index_todos/actions/list_recent_todos.rb`
- Modify: `workloads/missing_index_todos/actions/search_todos.rb`
- Modify: `workloads/missing_index_todos/actions/create_todo.rb`
- Modify: `workloads/missing_index_todos/actions/close_todo.rb`
- Modify: `workloads/missing_index_todos/actions/delete_completed_todos.rb`
- Modify: `workloads/missing_index_todos/test/workload_test.rb`
- Modify: action tests under `workloads/missing_index_todos/test/`

- [ ] **Step 1: Write the failing workload/action tests**

Add or update tests so they assert the tenant-shaped contract explicitly.

In `workloads/missing_index_todos/test/workload_test.rb`, add:

```ruby
def test_scale_exposes_user_count_in_extra
  workload = MissingIndexTodos::Workload.new

  assert_equal "1000", workload.scale.extra.fetch("USER_COUNT")
end
```

In the action tests, add cases like:

```ruby
def test_list_open_todos_scopes_request_to_one_user
  action = MissingIndexTodos::Actions::ListOpenTodos.new
  client = RecordingClient.new
  scale = Load::Scale.new(rows_per_table: 100_000, seed: 42, extra: { "USER_COUNT" => "1000" })

  action.call(client:, ctx: { base_url: "http://example.test", scale: }, rng: Random.new(7))

  assert_match %r{/api/todos\?}, client.last_path
  assert_includes client.last_path, "user_id="
  assert_includes client.last_path, "status=open"
end

def test_search_todos_scopes_request_to_one_user
  action = MissingIndexTodos::Actions::SearchTodos.new
  client = RecordingClient.new
  scale = Load::Scale.new(rows_per_table: 100_000, seed: 42, extra: { "USER_COUNT" => "1000" })

  action.call(client:, ctx: { base_url: "http://example.test", scale: }, rng: Random.new(7))

  assert_includes client.last_path, "user_id="
  assert_includes client.last_path, "q="
end

def test_create_todo_samples_user_id_from_user_count
  action = MissingIndexTodos::Actions::CreateTodo.new
  client = RecordingClient.new
  scale = Load::Scale.new(rows_per_table: 100_000, seed: 42, extra: { "USER_COUNT" => "25" })

  50.times do |index|
    action.call(client:, ctx: { base_url: "http://example.test", scale: }, rng: Random.new(index))
  end

  user_ids = client.request_bodies.map { |body| JSON.parse(body).fetch("user_id") }.uniq
  assert_operator user_ids.length, :>=, 5
  assert user_ids.all? { |id| (1..25).cover?(id) }
end

def test_delete_completed_todos_scopes_request_to_one_user_without_prefetch
  action = MissingIndexTodos::Actions::DeleteCompletedTodos.new
  client = RecordingClient.new
  scale = Load::Scale.new(rows_per_table: 100_000, seed: 42, extra: { "USER_COUNT" => "1000" })

  action.call(client:, ctx: { base_url: "http://example.test", scale: }, rng: Random.new(7))

  assert_equal 1, client.requests.length
  assert_equal :delete, client.requests.last.fetch(:method)
  assert_includes client.requests.last.fetch(:path), "user_id="
end

def test_close_todo_fetches_open_todos_for_one_user_before_patch
  action = MissingIndexTodos::Actions::CloseTodo.new
  client = RecordingClient.new(
    get_responses: [json_response([{ "id" => 12 }, { "id" => 18 }])],
  )
  scale = Load::Scale.new(rows_per_table: 100_000, seed: 42, extra: { "USER_COUNT" => "1000" })

  action.call(client:, ctx: { base_url: "http://example.test", scale: }, rng: Random.new(7))

  assert_equal :get, client.requests.first.fetch(:method)
  assert_includes client.requests.first.fetch(:path), "user_id="
  assert_includes client.requests.first.fetch(:path), "status=open"
  assert_equal :patch, client.requests.last.fetch(:method)
  assert_match %r{/api/todos/(12|18)$}, client.requests.last.fetch(:path)
end

def test_close_todo_is_noop_when_user_has_no_open_todos
  action = MissingIndexTodos::Actions::CloseTodo.new
  client = RecordingClient.new(get_responses: [json_response([])])
  scale = Load::Scale.new(rows_per_table: 100_000, seed: 42, extra: { "USER_COUNT" => "1000" })

  action.call(client:, ctx: { base_url: "http://example.test", scale: }, rng: Random.new(7))

  assert_equal 1, client.requests.length
  assert_equal :get, client.requests.first.fetch(:method)
end
```

- [ ] **Step 2: Run the focused workload/action tests and verify they fail**

Run:
```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby workloads/missing_index_todos/test/workload_test.rb
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby -e 'Dir["workloads/missing_index_todos/test/*_test.rb"].sort.each { |path| load path }'
```

Expected: failures because `USER_COUNT` is absent and actions are still globally shaped.

- [ ] **Step 3: Implement the minimal workload/action changes**

In `workloads/missing_index_todos/workload.rb`, change the default scale to include `USER_COUNT` in `extra`, for example:

```ruby
def scale
  Load::Scale.new(
    rows_per_table: 100_000,
    open_fraction: 0.6,
    seed: 42,
    extra: {
      "USER_COUNT" => "1000",
    },
  )
end
```

In the actions, add a shared helper pattern for sampling user ids from scale extras:

```ruby
def sample_user_id(scale, rng)
  user_count = Integer(scale.extra.fetch("USER_COUNT"))
  rng.rand(1..user_count)
end
```

Apply it so:
- `ListOpenTodos` sends `GET /api/todos?user_id=...&status=open`
- `ListRecentTodos` sends `GET /api/todos?user_id=...&page=...&per_page=...`
- `SearchTodos` sends `GET /api/todos/search?user_id=...&q=...`
- `CreateTodo` sends JSON with sampled `user_id`
- `DeleteCompletedTodos` sends `DELETE /api/todos/completed?user_id=...`
- `CloseTodo` first fetches `GET /api/todos?user_id=...&status=open`, picks one returned id, and only then sends `PATCH /api/todos/:id`

Keep the `CloseTodo` no-open-candidates path as a no-op success.

- [ ] **Step 4: Run the focused workload/action tests and verify they pass**

Run the same commands from Step 2.

Expected: green.

- [ ] **Step 5: Commit**

```bash
git add workloads/missing_index_todos/workload.rb \
  workloads/missing_index_todos/actions/*.rb \
  workloads/missing_index_todos/test/*.rb
git commit -m "refactor: make workload actions tenant scoped"
```

## Task 2: Make the Demo App Tenant-Shaped

**Files:**
- Modify: `/home/bjw/db-specialist-demo/db/seeds.rb`
- Modify: `/home/bjw/db-specialist-demo/config/routes.rb`
- Modify: `/home/bjw/db-specialist-demo/app/controllers/**/*.rb`
- Modify: `/home/bjw/db-specialist-demo/test/**/*_test.rb`

- [ ] **Step 1: Write the failing demo-app tests**

In the demo app, add/update controller tests that lock the tenant-scoped API:

```ruby
def test_index_filters_by_user_and_status
  user = users(:one)
  other_user = users(:two)
  open_for_user = Todo.create!(user:, title: "mine", status: "open")
  Todo.create!(user: other_user, title: "theirs", status: "open")

  get "/api/todos", params: { user_id: user.id, status: "open" }

  assert_response :success
  ids = JSON.parse(response.body).map { |todo| todo.fetch("id") }
  assert_equal [open_for_user.id], ids
end

def test_search_filters_by_user
  user = users(:one)
  other_user = users(:two)
  Todo.create!(user:, title: "buy milk", status: "open")
  Todo.create!(user: other_user, title: "buy milk", status: "open")

  get "/api/todos/search", params: { user_id: user.id, q: "milk" }

  assert_response :success
  ids = JSON.parse(response.body).map { |todo| todo.fetch("user_id") }.uniq
  assert_equal [user.id], ids
end

def test_delete_completed_is_user_scoped
  user = users(:one)
  other_user = users(:two)
  Todo.create!(user:, title: "done", status: "closed")
  survivor = Todo.create!(user: other_user, title: "done", status: "closed")

  delete "/api/todos/completed", params: { user_id: user.id }

  assert_response :success
  assert Todo.exists?(survivor.id)
end
```

In `db/seeds.rb` coverage or an app-level seed smoke, add a check that `USER_COUNT` controls created users.

- [ ] **Step 2: Run the focused demo-app tests and verify they fail**

Run in `~/db-specialist-demo` with the same benchmark env used elsewhere, for example:

```bash
SECRET_KEY_BASE=test RAILS_ENV=benchmark BUNDLE_USER_HOME=/tmp/bundle BUNDLE_PATH=vendor/bundle bundle exec rails test test/controllers/**/*_test.rb
```

Expected: failures because routes/controllers are not yet user-scoped.

- [ ] **Step 3: Implement the minimal tenant-shaped app changes**

Update `db/seeds.rb` to read `USER_COUNT`, create exactly that many users, and distribute todos across them.

In controllers/routes, make these request shapes valid:

```ruby
GET /api/todos?user_id=...&status=open|closed|all
GET /api/todos?user_id=...&page=...&per_page=...
GET /api/todos/search?user_id=...&q=...
POST /api/todos { user_id: ... }
PATCH /api/todos/:id
DELETE /api/todos/completed?user_id=...
```

Keep delete bounded and per-user. Do not reintroduce app-wide search/list semantics.

- [ ] **Step 4: Run the focused demo-app tests and verify they pass**

Run the same command from Step 2.

Expected: green.

- [ ] **Step 5: Commit in the demo app repo**

In `~/db-specialist-demo`:

```bash
git add db/seeds.rb config/routes.rb app/controllers test
git commit -m "refactor: make todo api user scoped"
```

## Task 3: Move Verifier Ownership Into the Workload

**Files:**
- Create: `workloads/missing_index_todos/verifier.rb`
- Modify: `workloads/missing_index_todos/workload.rb`
- Modify: `load/lib/load/workload.rb`
- Modify: `load/lib/load/cli.rb`
- Delete or remove references from: `load/lib/load/fixture_verifier.rb`
- Modify: `load/test/cli_test.rb`
- Create/modify: `workloads/missing_index_todos/test/verifier_test.rb`

- [ ] **Step 1: Write the failing verifier-boundary tests**

Add a workload-local verifier test:

```ruby
def test_verifier_checks_open_counts_and_search_for_missing_index_todos
  verifier = MissingIndexTodos::Verifier.new(
    explain_reader: ->(*) { explain_fixture },
    stats_reset: -> {},
    counts_calls_reader: -> { 2 },
    search_reference_reader: -> { search_fixture },
  )

  assert verifier.call(base_url: "http://example.test")
end
```

Add a CLI test that locks workload-owned verifier wiring without core todo-specific branching:

```ruby
def test_run_command_uses_workload_owned_verifier
  factory = FakeRunnerFactory.new(exit_code: 0)

  status = run_bin_load(
    "run",
    "--workload",
    "missing-index-todos",
    "--adapter",
    "fake-adapter",
    "--app-root",
    "/tmp/demo",
    runner_factory: factory,
  )

  assert_equal 0, status
  assert_instance_of MissingIndexTodos::Verifier, factory.calls.first.fetch(:config).verifier
end
```

- [ ] **Step 2: Run the focused verifier tests and verify they fail**

Run:
```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby workloads/missing_index_todos/test/verifier_test.rb
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/cli_test.rb --name test_run_command_uses_workload_owned_verifier
```

Expected: failures because verifier logic still lives in core load code or the workload has no dedicated verifier class.

- [ ] **Step 3: Implement the minimal verifier ownership shift**

Create `workloads/missing_index_todos/verifier.rb` and move the todo-specific verification logic there.

Shape:

```ruby
module MissingIndexTodos
  class Verifier
    def initialize(explain_reader:, stats_reset:, counts_calls_reader:, search_reference_reader:)
      @explain_reader = explain_reader
      @stats_reset = stats_reset
      @counts_calls_reader = counts_calls_reader
      @search_reference_reader = search_reference_reader
    end

    def call(base_url:)
      verify_open_todos_explain(base_url:)
      verify_counts_pathology(base_url:)
      verify_search_shape(base_url:)
      true
    end
  end
end
```

In `workload.rb`, change the workload hook to construct `MissingIndexTodos::Verifier` directly.

In `load/lib/load/cli.rb`, remove any remaining todo-specific verifier construction logic. The CLI should only do:

```ruby
verifier = workload.verifier(database_url: ENV["DATABASE_URL"], pg: PG)
```

If `load/lib/load/fixture_verifier.rb` becomes unused, remove it entirely from the namespace loader and repo. Do not keep a dead generic verifier shell around.

- [ ] **Step 4: Run the focused verifier tests and verify they pass**

Run the same commands from Step 2.

Expected: green.

- [ ] **Step 5: Run unchanged runner/CLI regression locks**

Run:
```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/cli_test.rb
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby load/test/runner_test.rb
```

Expected: green, proving verifier ownership moved without breaking runner/CLI semantics.

- [ ] **Step 6: Commit**

```bash
git add workloads/missing_index_todos/verifier.rb \
  workloads/missing_index_todos/workload.rb \
  workloads/missing_index_todos/test/verifier_test.rb \
  load/lib/load/workload.rb load/lib/load/cli.rb load/test/cli_test.rb load/test/runner_test.rb
# If removed:
git add load/lib/load.rb load/lib/load/fixture_verifier.rb
git commit -m "refactor: move verifier into workload"
```

## Task 4: End-to-End Verification

**Files:**
- Modify: `JOURNAL.md` only if verification reveals a non-obvious insight

- [ ] **Step 1: Run code-level suites in checkpoint-collector**

Run:
```bash
make test
```

Expected:
- `load` green
- `adapters` green with the same expected skips
- `workloads` green

- [ ] **Step 2: Run focused demo-app tests**

In `~/db-specialist-demo`:

```bash
SECRET_KEY_BASE=test RAILS_ENV=benchmark BUNDLE_USER_HOME=/tmp/bundle BUNDLE_PATH=vendor/bundle bundle exec rails test test/controllers/**/*_test.rb
```

Expected: green.

- [ ] **Step 3: Run the live finite path**

In `~/checkpoint-collector`:

```bash
DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo BENCH_ADAPTER_PG_ADMIN_URL=postgres://postgres:postgres@localhost:5432/postgres bin/load run --workload missing-index-todos --adapter adapters/rails/bin/bench-adapter --app-root /home/bjw/db-specialist-demo
latest=$(ls -1dt runs/* | head -n1)
DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo CLICKHOUSE_URL=http://localhost:8123 BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby workloads/missing_index_todos/oracle.rb "$latest"
```

Expected:
- finite run exits `0`
- oracle prints `PASS` lines

- [ ] **Step 4: Verify user-scoped traffic in the artifact or logs**

Use one or both of these sanity checks:

```bash
latest=$(ls -1dt runs/* | head -n1)
sed -n '1,220p' "$latest/run.json"
tail -n 20 /home/bjw/db-specialist-demo/log/benchmark.log
```

Expected:
- app routes now include `user_id` on list/search/delete paths
- no global all-user traffic pattern remains in the main workload actions

- [ ] **Step 5: Record any non-obvious verification insight in the journal and commit if needed**

Only if verification reveals something worth keeping, append one concise note to `JOURNAL.md`, then:

```bash
git add JOURNAL.md
git commit -m "docs: record tenant workload verification note"
```

If there is no new insight, skip this commit.

## Self-Review

### Spec Coverage

- `USER_COUNT` lives in `scale.extra`: covered in Task 1.
- read/search/write actions become user-scoped: covered in Tasks 1 and 2.
- `close_todo` fetches open candidates first: covered in Task 1.
- `delete_completed_todos` stays direct and user-scoped: covered in Tasks 1 and 2.
- demo app reads `USER_COUNT` and seeds a tenant-shaped dataset: covered in Task 2.
- verifier ownership moves fully into workload code: covered in Task 3.
- core runner/CLI keep treating verifier as optional callable only: covered in Task 3 regression locks.
- primary oracle remains green: covered in Task 4 live verification.

### Placeholder Scan

- No `TODO` / `TBD` placeholders remain.
- Every task includes exact files, code sketches, commands, and expected results.

### Type Consistency

- `USER_COUNT` is used consistently as an uppercase `scale.extra` key.
- `MissingIndexTodos::Verifier` is consistently named as the workload-owned verifier.
- `user_id` is consistently part of the request contract for list/search/delete/create flows.

Plan complete and saved to `docs/superpowers/plans/2026-04-25-tenant-shaped-workload-plan.md`. Two execution options:

1. Subagent-Driven (recommended) - I dispatch a fresh subagent per task, review between tasks, fast iteration

2. Inline Execution - Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
