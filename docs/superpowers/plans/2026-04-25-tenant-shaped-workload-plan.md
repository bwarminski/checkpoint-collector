# Tenant-Shaped Missing-Index Workload Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reshape `missing-index-todos` into a tenant-scoped workload, update adapter query-id attribution to the new query shape, and move verifier ownership fully into workload code without changing the primary oracle contract.

**Architecture:** Keep the core load library orchestration generic while moving todo-specific verification into `workloads/missing_index_todos/`. At the same time, make the demo app and workload actions tenant-shaped by reading `user_count` from `Load::Scale#extra`, scoping list/search/write traffic to one user, and teaching the adapter’s `reset-state` query-id capture about the new tenant-scoped query.

**Tech Stack:** Ruby, Minitest, Rails JSON API in `~/db-specialist-demo`, PostgreSQL `pg_stat_statements`, existing load runner/oracle infrastructure.

---

## File Map

- Modify: `workloads/missing_index_todos/workload.rb`
  - Add tenant-shaped scale extras and wire the workload-owned verifier.
- Create: `workloads/missing_index_todos/verifier.rb`
  - Own all `missing-index-todos` fixture verification logic.
- Modify: `workloads/missing_index_todos/actions/list_open_todos.rb`
  - Make request user-scoped.
- Modify: `workloads/missing_index_todos/actions/list_recent_todos.rb`
  - Make request user-scoped.
- Modify: `workloads/missing_index_todos/actions/search_todos.rb`
  - Make request user-scoped.
- Modify: `workloads/missing_index_todos/actions/create_todo.rb`
  - Sample `user_id` from `scale.extra[:user_count]`.
- Modify: `workloads/missing_index_todos/actions/close_todo.rb`
  - Fetch one user’s open todos before choosing a close target and return a 2xx no-op response when none exist.
- Modify: `workloads/missing_index_todos/actions/delete_completed_todos.rb`
  - Make delete request direct and user-scoped.
- Modify: `workloads/missing_index_todos/test/actions_test.rb`
  - Extend the existing `FakeClient` for stubbed GET responses and lock the new request shapes.
- Modify: `workloads/missing_index_todos/test/workload_test.rb`
  - Lock `user_count` in `scale.extra`.
- Create: `workloads/missing_index_todos/test/verifier_test.rb`
  - Cover verifier success and failure paths.
- Modify: `adapters/rails/lib/rails_adapter/commands/reset_state.rb`
  - Update `QUERY_IDS_SCRIPT["missing-index-todos"]` for the tenant-scoped query.
- Modify: `adapters/rails/test/reset_state_test.rb`
  - Lock non-empty query-id capture for the new query text.
- Modify: `load/lib/load/workload.rb`
  - Keep only the generic verifier hook contract.
- Modify: `load/lib/load/cli.rb`
  - Remove any remaining todo-specific verifier assumptions and rescue `Load::VerificationError`.
- Modify: `load/lib/load/runner.rb`
  - Rescue `Load::VerificationError` instead of `Load::FixtureVerifier::VerificationError`.
- Modify: `load/lib/load.rb` or create `load/lib/load/verification_error.rb`
  - Define `Load::VerificationError` in core load code.
- Delete: `load/lib/load/fixture_verifier.rb`
  - Remove todo-specific verification ownership from core load code.
- Modify: `load/test/cli_test.rb`
  - Lock workload-owned verifier wiring and the relocated error type.
- Modify: `load/test/runner_test.rb`
  - Lock runner rescue behavior against `Load::VerificationError`.
- Modify: `fixtures/mixed-todo-app/search-explain.json`
  - Re-capture the user-scoped search plan reference.
- Modify: `/home/bjw/db-specialist-demo/db/seeds.rb`
  - Read `USER_COUNT` and seed a tenant-shaped dataset.
- Modify: `/home/bjw/db-specialist-demo/config/routes.rb`
  - Express user-scoped JSON routes clearly.
- Modify: `/home/bjw/db-specialist-demo/app/models/user.rb`
  - Add `has_many :todos` if needed.
- Modify: `/home/bjw/db-specialist-demo/app/models/todo.rb`
  - Add/confirm `belongs_to :user`.
- Modify: `/home/bjw/db-specialist-demo/app/controllers/**/*.rb`
  - Scope list/search/delete behavior by `user_id`.
- Modify: `/home/bjw/db-specialist-demo/test/**/*_test.rb`
  - Add/update controller/model/seed tests for the tenant-shaped API.
- Modify: `JOURNAL.md`
  - Record any non-obvious decisions or verification findings.

## Task 0: Verify Demo App User Model Baseline

**Files:**
- Inspect or modify: `/home/bjw/db-specialist-demo/app/models/user.rb`
- Inspect or modify: `/home/bjw/db-specialist-demo/app/models/todo.rb`
- Inspect or modify: `/home/bjw/db-specialist-demo/test/fixtures/`
- Inspect or modify: `/home/bjw/db-specialist-demo/db/migrate/`

- [ ] **Step 1: Check whether the demo app already has the user/todo baseline**

Run:
```bash
cd /home/bjw/db-specialist-demo
rg -n "class User|has_many :todos|belongs_to :user" app test db
ls test/fixtures
```

Expected:
- either the full baseline exists already:
  - `app/models/user.rb`
  - `Todo` belongs to `:user`
  - user fixtures exist
  - a `todos.user_id` reference exists in schema/migrations
- or the missing pieces are obvious

- [ ] **Step 2: If missing, write the failing demo app baseline tests**

Only if Task 0 Step 1 shows the model baseline is incomplete, add:

```ruby
def test_todo_belongs_to_user
  todo = Todo.new
  assert_respond_to todo, :user
end

def test_user_has_many_todos
  user = User.new
  assert_respond_to user, :todos
end
```

- [ ] **Step 3: Run the baseline tests and verify they fail if the model baseline is absent**

Run:
```bash
cd /home/bjw/db-specialist-demo
bin/rails test
```

Expected:
- green if the baseline already exists
- otherwise clear failures showing the missing `User` / association / fixture pieces

- [ ] **Step 4: If needed, implement the minimal user/todo baseline**

Only if the baseline is missing:

```bash
cd /home/bjw/db-specialist-demo
bin/rails generate model User name:string
bin/rails generate migration AddUserToTodos user:references
bin/rails db:migrate
```

Then add:

```ruby
# app/models/user.rb
class User < ApplicationRecord
  has_many :todos, dependent: :destroy
end

# app/models/todo.rb
class Todo < ApplicationRecord
  belongs_to :user
end
```

And minimal user fixtures under `test/fixtures/users.yml`.

- [ ] **Step 5: Run the demo app baseline tests and verify they pass**

Run:
```bash
cd /home/bjw/db-specialist-demo
bin/rails test
```

Expected: baseline green before Task 1 begins.

- [ ] **Step 6: Commit in the demo app repo if changes were required**

Only if Task 0 changed the app:

```bash
cd /home/bjw/db-specialist-demo
git add app/models db/migrate test/fixtures
git commit -m "feat: add user model baseline"
```

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
- Modify: `workloads/missing_index_todos/test/actions_test.rb`

- [ ] **Step 1: Write the failing workload/action tests using the existing Action API and FakeClient**

In `workloads/missing_index_todos/test/workload_test.rb`, add:

```ruby
def test_scale_exposes_user_count_in_extra
  workload = Load::Workloads::MissingIndexTodos::Workload.new

  assert_equal 1_000, workload.scale.extra.fetch(:user_count)
end
```

In `workloads/missing_index_todos/test/actions_test.rb`, extend the existing `FakeClient` pattern instead of inventing a new client:

```ruby
class FakeClient
  attr_reader :requests

  def initialize(get_responses: {})
    @requests = []
    @get_responses = get_responses
  end

  def get(path)
    @requests << [:get, path, nil]
    @get_responses.fetch(path, default_response)
  end

  def request(method, path, body: nil, headers: {})
    @requests << [method, path, body]
    default_response
  end

  private

  def default_response
    OpenStruct.new(code: "200", body: "[]")
  end
end
```

Add action tests following the real API:

```ruby
def tenant_scale
  Load::Scale.new(rows_per_table: 100_000, seed: 42, extra: { user_count: 1_000 })
end

def test_list_open_todos_scopes_request_to_one_user
  client = FakeClient.new

  Load::Workloads::MissingIndexTodos::Actions::ListOpenTodos.new(
    rng: Random.new(7),
    ctx: { scale: tenant_scale },
    client:,
  ).call

  method, path, = client.requests.last
  assert_equal :get, method
  assert_includes path, "user_id="
  assert_includes path, "status=open"
end

def test_search_todos_scopes_request_to_one_user
  client = FakeClient.new

  Load::Workloads::MissingIndexTodos::Actions::SearchTodos.new(
    rng: Random.new(7),
    ctx: { scale: tenant_scale, query: "foo" },
    client:,
  ).call

  method, path, = client.requests.last
  assert_equal :get, method
  assert_includes path, "user_id="
  assert_includes path, "q=foo"
end

def test_create_todo_samples_user_id_from_user_count
  client = FakeClient.new
  scale = Load::Scale.new(rows_per_table: 100_000, seed: 42, extra: { user_count: 25 })

  100.times do |index|
    Load::Workloads::MissingIndexTodos::Actions::CreateTodo.new(
      rng: Random.new(index),
      ctx: { scale: },
      client:,
    ).call
  end

  user_ids = client.requests.filter_map do |method, _path, body|
    next unless method == :post
    body.fetch(:user_id)
  end.uniq

  assert_operator user_ids.length, :>=, 5
  assert user_ids.all? { |id| (1..25).cover?(id) }
end

def test_delete_completed_todos_scopes_request_to_one_user_without_prefetch
  client = FakeClient.new

  Load::Workloads::MissingIndexTodos::Actions::DeleteCompletedTodos.new(
    rng: Random.new(7),
    ctx: { scale: tenant_scale },
    client:,
  ).call

  assert_equal [[:delete, String, Hash]], [
    [client.requests.last[0], client.requests.last[1].class, client.requests.last[2].class],
  ]
  assert_includes client.requests.last[1], "user_id="
end

def test_close_todo_fetches_open_todos_for_one_user_before_patch
  path = "/api/todos?user_id=236&status=open"
  client = FakeClient.new(
    get_responses: {
      path => OpenStruct.new(code: "200", body: JSON.generate([{ id: 12 }, { id: 18 }]))
    },
  )

  Load::Workloads::MissingIndexTodos::Actions::CloseTodo.new(
    rng: Random.new(7),
    ctx: { scale: tenant_scale },
    client:,
  ).call

  assert_equal :get, client.requests.first[0]
  assert_includes client.requests.first[1], "user_id="
  assert_includes client.requests.first[1], "status=open"
  assert_equal :patch, client.requests.last[0]
  assert_match %r{/api/todos/(12|18)$}, client.requests.last[1]
end

def test_close_todo_no_op_returns_2xx_response
  path = "/api/todos?user_id=236&status=open"
  client = FakeClient.new(
    get_responses: {
      path => OpenStruct.new(code: "200", body: "[]")
    },
  )

  response = Load::Workloads::MissingIndexTodos::Actions::CloseTodo.new(
    rng: Random.new(7),
    ctx: { scale: tenant_scale },
    client:,
  ).call

  assert response.code.to_i.between?(200, 299)
  assert_equal 1, client.requests.length
  assert_equal :get, client.requests.first[0]
end
```

- [ ] **Step 2: Run the focused workload/action tests and verify they fail**

Run:
```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby workloads/missing_index_todos/test/workload_test.rb
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby workloads/missing_index_todos/test/actions_test.rb
```

Expected: failures because `user_count` is absent and actions are still globally shaped.

- [ ] **Step 3: Implement the minimal workload/action changes**

Use uniform native extra types in `workload.rb`:

```ruby
def scale
  Load::Scale.new(
    rows_per_table: 100_000,
    seed: 42,
    extra: {
      open_fraction: 0.6,
      user_count: 1_000,
    },
  )
end
```

In the actions, use a shared helper pattern:

```ruby
def sample_user_id
  user_count = Integer(ctx.fetch(:scale).extra.fetch(:user_count))
  rng.rand(1..user_count)
end
```

Apply it so:
- `ListOpenTodos` sends `GET /api/todos?user_id=...&status=open`
- `ListRecentTodos` sends `GET /api/todos?user_id=...&status=all&page=1&per_page=50&order=created_desc`
- `SearchTodos` sends `GET /api/todos/search?user_id=...&q=...`
- `CreateTodo` sends JSON with sampled `user_id`
- `DeleteCompletedTodos` sends `DELETE /api/todos/completed?user_id=...`

`FetchCounts` stays **global**:

```ruby
client.get("/api/todos/counts")
```

Do **not** add `user_id` to `FetchCounts`. The N+1 pathology is intentionally internal to the controller’s per-user iteration; tenant-scoping the route would remove the thing the verifier is supposed to detect.

For `CloseTodo`, define a no-op response:

```ruby
NoOpResponse = Struct.new(:code) do
  def body
    ""
  end
end
```

And implement the two-step shape:

```ruby
def call
  user_id = sample_user_id
  response = client.get("/api/todos?user_id=#{user_id}&status=open")
  ids = JSON.parse(response.body.to_s).map { |todo| todo.fetch("id") }
  return NoOpResponse.new("204") if ids.empty?

  todo_id = ids.sample(random: rng)
  client.request(:patch, "/api/todos/#{todo_id}", body: { status: "closed" })
end
```

- [ ] **Step 4: Run the focused workload/action tests and verify they pass**

Run the same commands from Step 2.

Expected: green.

- [ ] **Step 5: Commit**

```bash
git add workloads/missing_index_todos/workload.rb \
  workloads/missing_index_todos/actions/*.rb \
  workloads/missing_index_todos/test/workload_test.rb \
  workloads/missing_index_todos/test/actions_test.rb
git commit -m "refactor: make workload actions tenant scoped"
```

## Task 1.5: Update Adapter Query-Id Attribution

**Files:**
- Modify: `adapters/rails/lib/rails_adapter/commands/reset_state.rb`
- Modify: `adapters/rails/test/reset_state_test.rb`

- [ ] **Step 1: Write the failing adapter query-id test**

Add a focused test in `adapters/rails/test/reset_state_test.rb` asserting the new warm-up shape is captured:

```ruby
def test_reset_state_captures_query_ids_for_tenant_scoped_open_todos_query
  runner = FakeCommandRunner.new(
    responses: [
      success_capture3(""),
      success_capture3(""),
      success_capture3(JSON.generate(query_ids: ["123"])),
      success_capture3(""),
    ],
  )

  result = RailsAdapter::Commands::ResetState.new(
    app_root: "/tmp/app",
    seed: 42,
    env_pairs: { "USER_COUNT" => "1000" },
    workload: "missing-index-todos",
    command_runner: runner,
    template_cache: FakeTemplateCache.new(exists: false),
  ).call

  assert_equal true, result.fetch("ok")
  assert_equal ["123"], result.dig("payload", "query_ids")

  script = runner.commands.find { |command| command.include?("queryid") }
  assert_includes script, %("todos"."user_id" = $1 AND "todos"."status" = $2)
end
```

- [ ] **Step 2: Run the focused adapter test and verify it fails**

Run:
```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby adapters/rails/test/reset_state_test.rb --name test_reset_state_captures_query_ids_for_tenant_scoped_open_todos_query
```

Expected: failure because the warm-up and query text are still status-only.

- [ ] **Step 3: Update `QUERY_IDS_SCRIPT["missing-index-todos"]`**

In `adapters/rails/lib/rails_adapter/commands/reset_state.rb`, change the script to:

```ruby
QUERY_IDS_SCRIPT = {
  "missing-index-todos" => <<~RUBY.strip,
    require "json"
    user = User.first
    user.todos.with_status("open").ordered_by_created_desc.page(1, 50).load
    connection = ActiveRecord::Base.connection
    query_ids = [
      %(SELECT "todos".* FROM "todos" WHERE "todos"."user_id" = $1 AND "todos"."status" = $2 ORDER BY "todos"."created_at" DESC, "todos"."id" DESC LIMIT $3 OFFSET $4),
    ].flat_map do |query_text|
      connection.exec_query(
        "SELECT DISTINCT queryid::text AS queryid FROM pg_stat_statements WHERE query = \#{connection.quote(query_text)}"
      ).rows.flatten
    end.uniq
    $stdout.write(JSON.generate(query_ids: query_ids))
  RUBY
}.freeze
```

Before finalizing the exact normalized query text, run the real action once locally and copy the `pg_stat_statements.query` text verbatim. Do not guess the final normalized SQL.

- [ ] **Step 4: Run the focused adapter test and verify it passes**

Run the same command from Step 2.

Expected: green and non-empty `query_ids`.

- [ ] **Step 5: Commit**

```bash
git add adapters/rails/lib/rails_adapter/commands/reset_state.rb adapters/rails/test/reset_state_test.rb
git commit -m "fix: capture tenant scoped query ids"
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

def test_seeds_creates_exact_user_count
  original_user_count = ENV["USER_COUNT"]
  ENV["USER_COUNT"] = "7"

  load Rails.root.join("db/seeds.rb")

  assert_equal 7, User.count
ensure
  ENV["USER_COUNT"] = original_user_count
end
```

- [ ] **Step 2: Run the focused demo-app tests and verify they fail**

Run in `~/db-specialist-demo` with the same benchmark env used elsewhere:

```bash
cd /home/bjw/db-specialist-demo
SECRET_KEY_BASE=test RAILS_ENV=benchmark BUNDLE_USER_HOME=/tmp/bundle BUNDLE_PATH=vendor/bundle bundle exec rails test test/controllers/**/*_test.rb
```

Expected: failures because routes/controllers/seeds are not yet fully user-scoped.

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
git add db/seeds.rb config/routes.rb app/models app/controllers test
git commit -m "refactor: make todo api user scoped"
```

## Task 3: Move Verifier Ownership Into the Workload

**Files:**
- Create: `workloads/missing_index_todos/verifier.rb`
- Modify: `workloads/missing_index_todos/workload.rb`
- Modify: `load/lib/load/workload.rb`
- Modify: `load/lib/load/cli.rb`
- Modify: `load/lib/load/runner.rb`
- Modify: `load/lib/load.rb` or create `load/lib/load/verification_error.rb`
- Delete: `load/lib/load/fixture_verifier.rb`
- Modify: `load/test/cli_test.rb`
- Modify: `load/test/runner_test.rb`
- Create/modify: `workloads/missing_index_todos/test/verifier_test.rb`
- Modify: `fixtures/mixed-todo-app/search-explain.json`

- [ ] **Step 1: Write the failing verifier-boundary tests**

Add a workload-local verifier success test:

```ruby
def test_verifier_checks_open_counts_and_search_for_missing_index_todos
  verifier = Load::Workloads::MissingIndexTodos::Verifier.new(
    client_factory: ->(*) { FakeClient.new("/api/todos/counts" => OpenStruct.new(code: "200", body: JSON.generate([{ "id" => 1 }, { "id" => 2 }])) ) },
    explain_reader: ->(sql) { sql.include?("title LIKE") ? search_fixture : missing_index_fixture },
    stats_reset: -> {},
    counts_calls_reader: -> { 2 },
    search_reference_reader: -> { search_fixture },
  )

  assert verifier.call(base_url: "http://example.test")
end
```

Add the three failure-path tests:

```ruby
def test_verifier_raises_when_explain_shows_index_scan
  verifier = build_verifier(explain_reader: ->(*) { index_scan_fixture })
  assert_raises(Load::VerificationError) { verifier.call(base_url: "http://example.test") }
end

def test_verifier_raises_when_counts_calls_below_user_count
  verifier = build_verifier(
    client_factory: ->(*) { FakeClient.new("/api/todos/counts" => OpenStruct.new(code: "200", body: JSON.generate([{ "id" => 1 }, { "id" => 2 }])) ) },
    counts_calls_reader: -> { 1 },
  )
  assert_raises(Load::VerificationError) { verifier.call(base_url: "http://example.test") }
end

def test_verifier_raises_when_search_plan_drifts_from_reference
  verifier = build_verifier(search_reference_reader: -> { drifted_search_fixture })
  assert_raises(Load::VerificationError) { verifier.call(base_url: "http://example.test") }
end
```

Add a CLI test:

```ruby
def test_run_command_uses_workload_owned_verifier
  factory = FakeRunnerFactory.new(exit_code: 0)

  status = run_bin_load(
    "run",
    "--workload", "missing-index-todos",
    "--adapter", "fake-adapter",
    "--app-root", "/tmp/demo",
    runner_factory: factory,
  )

  assert_equal 0, status
  assert_instance_of Load::Workloads::MissingIndexTodos::Verifier, factory.calls.first.fetch(:config).verifier
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

Promote the shared error marker into core load code:

```ruby
module Load
  VerificationError = Class.new(StandardError)
end
```

Then update all rescue sites:

```ruby
rescue Load::VerificationError => error
```

Create `workloads/missing_index_todos/verifier.rb` with this shape:

```ruby
module Load
  module Workloads
    module MissingIndexTodos
      class Verifier
        def initialize(client_factory: nil, explain_reader: nil, stats_reset: nil, counts_calls_reader: nil, search_reference_reader: nil, database_url: ENV["DATABASE_URL"], pg: PG)
          @client_factory = client_factory || ->(base_url) { Load::Client.new(base_url:) }
          @explain_reader = explain_reader || self.class.build_explain_reader(database_url:, pg:)
          @stats_reset = stats_reset || self.class.build_stats_reset(database_url:, pg:)
          @counts_calls_reader = counts_calls_reader || self.class.build_counts_calls_reader(database_url:, pg:)
          @search_reference_reader = search_reference_reader || -> { JSON.parse(File.read(search_reference_path)).fetch(0).fetch("Plan") }
        end

        def call(base_url:)
          verify_missing_index(base_url:)
          verify_counts_n_plus_one(base_url:)
          verify_search_rewrite(base_url:)
          true
        end
      end
    end
  end
end
```

In `workload.rb`, construct it directly from the workload hook:

```ruby
def verifier(database_url:, pg:)
  Load::Workloads::MissingIndexTodos::Verifier.new(database_url:, pg:)
end
```

In `load/lib/load/cli.rb`, keep only generic verifier acquisition:

```ruby
verifier = workload.verifier(database_url: ENV["DATABASE_URL"], pg: PG)
```

Delete `load/lib/load/fixture_verifier.rb` and remove its namespace load.

Also re-capture `fixtures/mixed-todo-app/search-explain.json` from the new user-scoped search query:

```sql
EXPLAIN (FORMAT JSON)
SELECT *
FROM todos
WHERE user_id = 1 AND title LIKE '%foo%'
ORDER BY created_at DESC, id DESC
LIMIT 50
```

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
  load/lib/load/workload.rb \
  load/lib/load/cli.rb \
  load/lib/load/runner.rb \
  load/lib/load.rb \
  load/test/cli_test.rb \
  load/test/runner_test.rb \
  fixtures/mixed-todo-app/search-explain.json
git rm load/lib/load/fixture_verifier.rb
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

Before the live run, capture the current dominance ratio from a recent PASS run for comparison. If the post-change ratio falls below `3.5x`, stop and escalate before retuning weights.

- [ ] **Step 2: Run focused demo-app tests**

In `~/db-specialist-demo`:

```bash
cd /home/bjw/db-specialist-demo
SECRET_KEY_BASE=test RAILS_ENV=benchmark BUNDLE_USER_HOME=/tmp/bundle BUNDLE_PATH=vendor/bundle bundle exec rails test test/controllers/**/*_test.rb
```

Expected: green.

- [ ] **Step 3: Run the live finite path**

In `~/checkpoint-collector`:

```bash
DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo \
BENCH_ADAPTER_PG_ADMIN_URL=postgres://postgres:postgres@localhost:5432/postgres \
bin/load run --workload missing-index-todos --adapter adapters/rails/bin/bench-adapter \
  --app-root /home/bjw/db-specialist-demo
latest=$(ls -1dt runs/* | head -n1)
sed -n '1,220p' "$latest/run.json"
DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo \
CLICKHOUSE_URL=http://localhost:8123 \
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby \
workloads/missing_index_todos/oracle.rb "$latest"
```

Expected:
- finite run exits `0`
- `run.json` shows non-empty `query_ids`
- oracle prints `PASS` lines including dominance ratio
- if dominance drops below `3.5x`, stop and escalate before tuning weights

- [ ] **Step 4: Verify user-scoped traffic and cleanup boundaries**

Run:
```bash
tail -n 20 /home/bjw/db-specialist-demo/log/benchmark.log
grep -rn "FixtureVerifier" load/lib/load adapters/rails
grep -rn "rows_per_table" workloads/missing_index_todos/actions
```

Expected:
- app traffic includes `user_id=` on list/search/delete paths
- `grep -rn "FixtureVerifier"` returns nothing
- `grep -rn "rows_per_table"` returns nothing in workload actions

- [ ] **Step 5: Record any non-obvious verification insight in the journal and commit if needed**

Only if verification reveals something worth keeping, append one concise note to `JOURNAL.md`, then:

```bash
git add JOURNAL.md
git commit -m "docs: record tenant workload verification note"
```

If there is no new insight, skip this commit.

## Self-Review

### Spec Coverage

- `user_count` stays in `scale.extra`: covered in Task 1.
- read/search/write actions become user-scoped: covered in Tasks 1 and 2.
- `close_todo` fetches open candidates first and returns a 2xx no-op response when empty: covered in Task 1.
- `delete_completed_todos` stays direct and user-scoped: covered in Tasks 1 and 2.
- `fetch_counts` stays global: covered in Task 1.
- demo app reads `USER_COUNT` and seeds a tenant-shaped dataset: covered in Tasks 0 and 2.
- adapter `QUERY_IDS_SCRIPT` is updated for the new tenant-scoped query: covered in Task 1.5.
- verifier ownership moves fully into workload code: covered in Task 3.
- `Load::VerificationError` replaces the old core verifier-specific error class: covered in Task 3.
- search-explain reference fixture is re-captured: covered in Task 3.
- primary oracle remains green and dominance is compared against baseline: covered in Task 4.

### Placeholder Scan

- No `TODO` / `TBD` placeholders remain.
- Every task includes exact files, code sketches, commands, and expected results.

### Type Consistency

- `user_count` is used consistently as a symbol key in `scale.extra`.
- `Load::VerificationError` is consistently the shared verifier error marker.
- `Load::Workloads::MissingIndexTodos::Verifier` is consistently named as the workload-owned verifier.
- `user_id` is consistently part of the tenant-scoped request contract for list/search/delete/create flows.

Plan complete and saved to `docs/superpowers/plans/2026-04-25-tenant-shaped-workload-plan.md`. Two execution options:

1. Subagent-Driven (recommended) - I dispatch a fresh subagent per task, review between tasks, fast iteration

2. Inline Execution - Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
