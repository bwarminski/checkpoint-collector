# Workload-Owned Rails Query IDs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move missing-index todos query-id capture ownership out of the Rails adapter and into the workload directory while preserving reset/reseed behavior.

**Architecture:** `RailsAdapter::Commands::ResetState` keeps Rails mechanics: reset strategy, seeding, `pg_stat_statements` setup/reset, `bin/rails runner`, JSON parsing, and adapter result shape. Workloads may provide an optional Rails query-id script at `workloads/<workload_name.tr("-", "_")>/rails/reset_state_query_ids.rb`; if absent, reset still succeeds without `query_ids`.

**Tech Stack:** Ruby, Minitest, Rails adapter subprocess command runner, `pg_stat_statements`, workload files under `workloads/`.

---

## File Map

- Modify `adapters/rails/lib/rails_adapter.rb`: define stable adapter and repository root anchors.
- Modify `adapters/rails/lib/rails_adapter/commands/reset_state.rb`: remove hardcoded `QUERY_IDS_SCRIPT`, resolve optional workload-owned Rails query-id script by convention, pass its path to `bin/rails runner`.
- Modify `adapters/rails/test/reset_state_test.rb`: replace constant-based tests with temporary workload-script fixtures, missing-script behavior, and failure-detail coverage.
- Create `workloads/missing_index_todos/rails/reset_state_query_ids.rb`: Rails-context script that warms and captures the tenant-scoped open-todos statement family.
- Modify `workloads/missing_index_todos/test/workload_test.rb`: lock the workload-owned Rails script path and query shape.
- Modify `remote-soak-walkthrough.md` only if `showboat verify` reports stale captured snippets after code changes.

## Task 1: Add Adapter Tests for Workload-Owned Query Scripts

**Files:**
- Modify: `adapters/rails/test/reset_state_test.rb`

- [ ] **Step 1: Write failing tests for conventional workload script lookup and missing-script behavior**

In `adapters/rails/test/reset_state_test.rb`, add these helper methods inside the `private` section, before `with_env`:

```ruby
  def write_workload_query_ids_script(root:, workload:, body:)
    directory = File.join(root, workload.tr("-", "_"), "rails")
    FileUtils.mkdir_p(directory)
    path = File.join(directory, "reset_state_query_ids.rb")
    File.write(path, body)
    path
  end

  def query_ids_script_body
    <<~RUBY
      require "json"
      $stdout.write(JSON.generate(query_ids: ["111"]))
    RUBY
  end
```

Add `require "fileutils"` near the top of the test file:

```ruby
require "fileutils"
require_relative "test_helper"
```

Replace `test_reset_state_remote_strategy_skips_template_cache_and_runs_schema_seed_and_stats_steps` with:

```ruby
  def test_reset_state_remote_strategy_skips_template_cache_and_runs_schema_seed_and_stats_steps
    Dir.mktmpdir do |workload_root|
      script_body = query_ids_script_body
      script_path = write_workload_query_ids_script(root: workload_root, workload: "missing-index-todos", body: script_body)
      query_ids_json = %({"query_ids":["111"]})
      runner = FakeCommandRunner.new(
        results: {
          ["bin/rails", "runner", script_path] => FakeResult.new(status: 0, stdout: query_ids_json, stderr: ""),
        },
      )
      cache = FakeTemplateCache.new
      command = RailsAdapter::Commands::ResetState.new(
        app_root: "/tmp/demo",
        workload: "missing-index-todos",
        seed: 42,
        env_pairs: { "ROWS_PER_TABLE" => "100000", "OPEN_FRACTION" => "0.6", "USER_COUNT" => "100" },
        command_runner: runner,
        template_cache: cache,
        reset_strategy: "remote",
        workload_root:,
        clock: fake_clock(0.0, 1.0),
      )

      result = command.call

      assert result.fetch("ok"), result.inspect
      assert_equal ["111"], result.fetch("query_ids")
      assert_equal 0, cache.build_calls
      assert_equal 0, cache.clone_calls
      assert_equal [
        ["bin/rails", "db:schema:load"],
        ["bin/rails", "runner", %(load Rails.root.join("db/seeds.rb").to_s)],
        ["bin/rails", "runner", %(ActiveRecord::Base.connection.execute("CREATE EXTENSION IF NOT EXISTS pg_stat_statements"))],
        ["bin/rails", "runner", script_path],
        ["bin/rails", "runner", %(ActiveRecord::Base.connection.execute("SELECT pg_stat_statements_reset()"))],
      ], runner.argv_history
    end
  end
```

Add this new test after the remote success test:

```ruby
  def test_reset_state_skips_query_id_capture_when_workload_script_is_absent
    Dir.mktmpdir do |workload_root|
      runner = FakeCommandRunner.new
      command = RailsAdapter::Commands::ResetState.new(
        app_root: "/tmp/demo",
        workload: "fixture-workload",
        seed: 42,
        env_pairs: {},
        command_runner: runner,
        template_cache: FakeTemplateCache.new,
        reset_strategy: "remote",
        workload_root:,
        clock: fake_clock(0.0, 1.0),
      )

      result = command.call

      assert result.fetch("ok"), result.inspect
      refute result.key?("query_ids")
      refute runner.argv_history.any? { |argv| argv.first(2) == ["bin/rails", "runner"] && argv.fetch(2).include?("query_ids") }
    end
  end
```

Add this new test after `test_reset_state_skips_query_id_capture_when_workload_script_is_absent`:

```ruby
  def test_reset_state_skips_query_id_capture_when_workload_is_nil
    Dir.mktmpdir do |workload_root|
      runner = FakeCommandRunner.new
      command = RailsAdapter::Commands::ResetState.new(
        app_root: "/tmp/demo",
        seed: 42,
        env_pairs: {},
        command_runner: runner,
        template_cache: FakeTemplateCache.new(template_exists: true),
        reset_strategy: "remote",
        workload_root:,
        clock: fake_clock(0.0, 1.0),
      )

      result = command.call

      assert result.fetch("ok"), result.inspect
      refute result.key?("query_ids")
    end
  end
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby adapters/rails/test/reset_state_test.rb
```

Expected: fails with `unknown keyword: :workload_root`.

## Task 2: Implement Conventional Query Script Resolution

**Files:**
- Modify: `adapters/rails/lib/rails_adapter.rb`
- Modify: `adapters/rails/lib/rails_adapter/commands/reset_state.rb`
- Test: `adapters/rails/test/reset_state_test.rb`

- [ ] **Step 1: Remove the hardcoded `QUERY_IDS_SCRIPT` constant**

Delete the entire `QUERY_IDS_SCRIPT = { ... }.freeze` constant from `ResetState`.

- [ ] **Step 2: Add stable Rails adapter root constants**

In `adapters/rails/lib/rails_adapter.rb`, add root anchors inside the existing `RailsAdapter` module at the bottom of the file:

```ruby
module RailsAdapter
  ROOT = File.expand_path("../..", __dir__)
  REPO_ROOT = File.expand_path("../..", ROOT)
end
```

Do not add a config object. The constants are the single path anchor used by adapter commands.

- [ ] **Step 3: Add `workload_root` to the initializer**

Change the initializer signature in `ResetState` to:

```ruby
      def initialize(app_root:, seed:, env_pairs:, workload: nil, command_runner: RailsAdapter::CommandRunner.new, template_cache: RailsAdapter::TemplateCache.new, reset_strategy: ENV.fetch("BENCH_ADAPTER_RESET_STRATEGY", "local"), workload_root: File.join(RailsAdapter::REPO_ROOT, "workloads"), clock: -> { Time.now.to_f })
        @app_root = app_root
        @workload = workload
        @seed = seed
        @env_pairs = env_pairs
        @command_runner = command_runner
        @template_cache = template_cache
        @reset_strategy = reset_strategy
        @workload_root = workload_root
        @clock = clock
      end
```

- [ ] **Step 4: Replace query-id capture with script-path lookup**

Replace `capture_query_ids` with:

```ruby
      def capture_query_ids
        path = query_ids_script_path
        return nil unless path

        result = @command_runner.capture3(
          "bin/rails",
          "runner",
          path,
          env: rails_env,
          chdir: @app_root,
          command_name: "reset-state",
        )
        raise command_failure_message("query id capture failed", result.stderr) unless result.success?

        JSON.parse(result.stdout).fetch("query_ids")
      end

      def query_ids_script_path
        return nil unless @workload

        path = File.join(@workload_root, @workload.tr("-", "_"), "rails", "reset_state_query_ids.rb")
        File.exist?(path) ? path : nil
      end
```

- [ ] **Step 5: Verify the root anchor resolves the repository workloads directory**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby -Iadapters/rails/lib -e 'require "rails_adapter"; path = File.join(RailsAdapter::REPO_ROOT, "workloads"); abort("missing #{path}") unless File.exist?(path); puts path'
```

Expected: prints the absolute repository `workloads` path.

- [ ] **Step 6: Run reset-state tests and verify progress**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby adapters/rails/test/reset_state_test.rb
```

Expected: remaining failures reference `QUERY_IDS_SCRIPT` in older tests.

## Task 3: Finish Adapter Test Migration and Failure Coverage

**Files:**
- Modify: `adapters/rails/test/reset_state_test.rb`

- [ ] **Step 1: Replace query-id return test**

Replace `test_reset_state_returns_query_ids_for_missing_index_workload` with:

```ruby
  def test_reset_state_returns_query_ids_from_workload_script
    Dir.mktmpdir do |workload_root|
      script_body = query_ids_script_body
      script_path = write_workload_query_ids_script(root: workload_root, workload: "missing-index-todos", body: script_body)
      query_ids_json = %({"query_ids":["111","222"]})
      runner = FakeCommandRunner.new(
        results: {
          ["bin/rails", "runner", script_path] => FakeResult.new(status: 0, stdout: query_ids_json, stderr: ""),
        },
      )
      command = RailsAdapter::Commands::ResetState.new(
        app_root: "/tmp/demo",
        workload: "missing-index-todos",
        seed: 42,
        env_pairs: {},
        command_runner: runner,
        template_cache: FakeTemplateCache.new(template_exists: true),
        workload_root:,
        clock: fake_clock(0.0, 1.0),
      )

      result = command.call

      assert_equal ["111", "222"], result.fetch("query_ids")
    end
  end
```

- [ ] **Step 2: Replace the old in-adapter script-shape test with a constant-removal test**

Delete `test_reset_state_query_id_script_matches_tenant_scoped_open_todos_query_shape` and add:

```ruby
  def test_reset_state_does_not_embed_workload_query_id_scripts
    refute RailsAdapter::Commands::ResetState.const_defined?(:QUERY_IDS_SCRIPT)
  end
```

- [ ] **Step 3: Add failure-detail test for workload query-id script failures**

Add this test near the other remote failure tests:

```ruby
  def test_reset_state_reports_workload_query_id_script_failure_details
    Dir.mktmpdir do |workload_root|
      script_body = query_ids_script_body
      script_path = write_workload_query_ids_script(root: workload_root, workload: "missing-index-todos", body: script_body)
      runner = FakeCommandRunner.new(
        results: {
          ["bin/rails", "runner", script_path] => FakeResult.new(status: 1, stdout: "", stderr: "query lookup failed"),
        },
      )
      command = RailsAdapter::Commands::ResetState.new(
        app_root: "/tmp/demo",
        workload: "missing-index-todos",
        seed: 42,
        env_pairs: {},
        command_runner: runner,
        template_cache: FakeTemplateCache.new(template_exists: true),
        workload_root:,
        clock: fake_clock(0.0, 1.0),
      )

      result = command.call

      refute result.fetch("ok")
      assert_equal "reset_failed", result.fetch("error").fetch("code")
      assert_includes result.fetch("error").fetch("message"), "query id capture failed"
      assert_includes result.fetch("error").fetch("message"), "query lookup failed"
    end
  end
```

- [ ] **Step 4: Add missing `query_ids` JSON contract test**

Add this test after `test_reset_state_reports_workload_query_id_script_failure_details`:

```ruby
  def test_reset_state_reports_when_workload_query_id_script_omits_query_ids
    Dir.mktmpdir do |workload_root|
      script_body = query_ids_script_body
      script_path = write_workload_query_ids_script(root: workload_root, workload: "missing-index-todos", body: script_body)
      runner = FakeCommandRunner.new(
        results: {
          ["bin/rails", "runner", script_path] => FakeResult.new(status: 0, stdout: %({"ok":true}), stderr: ""),
        },
      )
      command = RailsAdapter::Commands::ResetState.new(
        app_root: "/tmp/demo",
        workload: "missing-index-todos",
        seed: 42,
        env_pairs: {},
        command_runner: runner,
        template_cache: FakeTemplateCache.new(template_exists: true),
        workload_root:,
        clock: fake_clock(0.0, 1.0),
      )

      result = command.call

      refute result.fetch("ok")
      assert_equal "reset_failed", result.fetch("error").fetch("code")
      assert_includes result.fetch("error").fetch("message"), "key not found"
      assert_includes result.fetch("error").fetch("message"), "query_ids"
    end
  end
```

- [ ] **Step 5: Add invalid JSON output test**

Add this test after `test_reset_state_reports_when_workload_query_id_script_omits_query_ids`:

```ruby
  def test_reset_state_reports_when_workload_query_id_script_outputs_invalid_json
    Dir.mktmpdir do |workload_root|
      script_body = query_ids_script_body
      script_path = write_workload_query_ids_script(root: workload_root, workload: "missing-index-todos", body: script_body)
      runner = FakeCommandRunner.new(
        results: {
          ["bin/rails", "runner", script_path] => FakeResult.new(status: 0, stdout: "not json", stderr: ""),
        },
      )
      command = RailsAdapter::Commands::ResetState.new(
        app_root: "/tmp/demo",
        workload: "missing-index-todos",
        seed: 42,
        env_pairs: {},
        command_runner: runner,
        template_cache: FakeTemplateCache.new(template_exists: true),
        workload_root:,
        clock: fake_clock(0.0, 1.0),
      )

      result = command.call

      refute result.fetch("ok")
      assert_equal "reset_failed", result.fetch("error").fetch("code")
    end
  end
```

- [ ] **Step 6: Run reset-state tests**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby adapters/rails/test/reset_state_test.rb
```

Expected: all reset-state tests pass.

- [ ] **Step 7: Commit adapter refactor**

Run:

```bash
git status --short
git add adapters/rails/lib/rails_adapter/commands/reset_state.rb adapters/rails/test/reset_state_test.rb
git commit -m "refactor: load reset query ids from workloads"
```

## Task 4: Move the Missing-Index Rails Query Script into the Workload

**Files:**
- Create: `workloads/missing_index_todos/rails/reset_state_query_ids.rb`
- Modify: `workloads/missing_index_todos/test/workload_test.rb`

- [ ] **Step 1: Write failing workload test for script ownership and query shape**

Add this test to `MissingIndexTodosWorkloadTest` after `test_workload_builds_a_missing_index_fixture_verifier`:

```ruby
  def test_workload_owns_rails_query_id_script
    path = File.expand_path("../rails/reset_state_query_ids.rb", __dir__)

    script = File.read(path)

    assert_includes script, "User.first"
    assert_includes script, %(user.todos.with_status("open").ordered_by_created_desc.page(1, 50).load)
    assert_includes script, %(with_status("open"))
    assert_includes script, %(SELECT "todos".* FROM "todos" WHERE "todos"."user_id" = $1 AND "todos"."status" = $2 ORDER BY "todos"."created_at" DESC, "todos"."id" DESC LIMIT $3 OFFSET $4)
    assert_includes script, "JSON.generate(query_ids: query_ids)"
  end
```

- [ ] **Step 2: Run workload test and verify failure**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby workloads/missing_index_todos/test/workload_test.rb
```

Expected: fails with `No such file or directory @ rb_sysopen`.

- [ ] **Step 3: Create the workload-owned Rails script**

Create `workloads/missing_index_todos/rails/reset_state_query_ids.rb`:

```ruby
# ABOUTME: Captures the Rails pg_stat_statements query IDs for the missing-index workload.
# ABOUTME: Warms the tenant-scoped open-todos query and emits JSON for the Rails adapter.
require "json"

user = User.first or raise("expected a seeded user")
user.todos.with_status("open").ordered_by_created_desc.page(1, 50).load
connection = ActiveRecord::Base.connection
query_ids = [
  %(SELECT "todos".* FROM "todos" WHERE "todos"."user_id" = $1 AND "todos"."status" = $2 ORDER BY "todos"."created_at" DESC, "todos"."id" DESC LIMIT $3 OFFSET $4),
].flat_map do |query_text|
  connection.exec_query(
    "SELECT DISTINCT queryid::text AS queryid FROM pg_stat_statements WHERE query = #{connection.quote(query_text)}"
  ).rows.flatten
end.uniq
$stdout.write(JSON.generate(query_ids: query_ids))
```

- [ ] **Step 4: Add default workload-root regression test**

Add this test to `adapters/rails/test/reset_state_test.rb` after `test_reset_state_does_not_embed_workload_query_id_scripts`:

```ruby
  def test_reset_state_default_workload_root_resolves_to_real_workload_script
    command = RailsAdapter::Commands::ResetState.new(
      app_root: "/tmp/demo",
      workload: "missing-index-todos",
      seed: 42,
      env_pairs: {},
    )
    path = command.send(:query_ids_script_path)

    refute_nil path, "default workload_root must resolve missing-index-todos script"
    assert File.exist?(path), "expected real workload script at #{path}"
    assert_match %r{/workloads/missing_index_todos/rails/reset_state_query_ids\.rb\z}, path
  end
```

- [ ] **Step 5: Run workload test**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby workloads/missing_index_todos/test/workload_test.rb
```

Expected: all workload contract tests pass.

- [ ] **Step 6: Run reset-state tests with the real workload file present**

Run:

```bash
BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby adapters/rails/test/reset_state_test.rb
```

Expected: all reset-state tests pass.

- [ ] **Step 7: Commit workload script and default-root regression**

Run:

```bash
git status --short
git add adapters/rails/test/reset_state_test.rb workloads/missing_index_todos/rails/reset_state_query_ids.rb workloads/missing_index_todos/test/workload_test.rb
git commit -m "refactor: move missing index query ids to workload"
```

## Task 5: Full Verification and Generated Walkthrough Refresh

**Files:**
- Modify: `remote-soak-walkthrough.md` only if verification reports stale snippets.

- [ ] **Step 1: Run adapter suite**

Run:

```bash
make test-adapters
```

Expected: adapter tests pass with the existing two integration skips unchanged.

- [ ] **Step 2: Run workload suite**

Run:

```bash
make test-workloads
```

Expected: workload tests pass.

- [ ] **Step 3: Run load suite**

Run:

```bash
make test-load
```

Expected: load tests pass.

- [ ] **Step 4: Verify the showboat walkthrough**

Run:

```bash
uvx showboat verify remote-soak-walkthrough.md --output /tmp/remote-soak-walkthrough.updated.md
```

Expected: exits 0. If it exits 1 because captured source snippets changed, replace the walkthrough with the updated output and verify again:

```bash
cp /tmp/remote-soak-walkthrough.updated.md remote-soak-walkthrough.md
uvx showboat verify remote-soak-walkthrough.md
```

- [ ] **Step 5: Run final diff checks**

Run:

```bash
git diff --check
rg -n "QUERY_IDS_SCRIPT" adapters/rails workloads load || true
```

Expected: no whitespace errors. The `rg` command should produce no output.

- [ ] **Step 6: Commit verification artifacts if needed**

If `remote-soak-walkthrough.md` changed, run:

```bash
git add remote-soak-walkthrough.md
git commit -m "docs: refresh remote soak walkthrough"
```

If it did not change, do not create a commit for this task.

## Self-Review Notes

- Spec coverage: the plan moves the script out of `ResetState`, preserves Rails execution in the adapter, supports missing scripts, covers nil workload, covers omitted and invalid `query_ids` output, verifies default workload-root resolution, preserves `run.json.query_ids`, and keeps behavior for `missing-index-todos`.
- Vague-instruction scan: all implementation tasks include exact files, snippets, commands, and expected outcomes.
- Type consistency: the plan uses `workload_root:` consistently as the injected test seam and keeps `query_ids` as the existing top-level adapter/run-record field.
