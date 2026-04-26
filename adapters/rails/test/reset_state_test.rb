# ABOUTME: Verifies the reset-state command rebuilds or clones a template database.
# ABOUTME: Ensures reset-state also clears pg_stat_statements counters after seeding.
require "fileutils"
require_relative "test_helper"

class ResetStateTest < Minitest::Test
  def test_reset_state_uses_database_name_from_database_url
    runner = FakeCommandRunner.new
    cache = FakeTemplateCache.new
    command = RailsAdapter::Commands::ResetState.new(
      app_root: "/tmp/demo",
      seed: 42,
      env_pairs: {},
      command_runner: runner,
      template_cache: cache,
      clock: fake_clock(0.0, 1.0),
    )

    with_env("DATABASE_URL" => "postgres://postgres:postgres@localhost:5432/custom_benchmark") do
      command.call
    end

    assert_equal "custom_benchmark", cache.last_build_args.fetch(:database_name)
  end

  def test_reset_state_uses_template_clone_after_first_build
    runner = FakeCommandRunner.new
    cache = FakeTemplateCache.new
    command = RailsAdapter::Commands::ResetState.new(
      app_root: "/tmp/demo",
      seed: 42,
      env_pairs: {},
      command_runner: runner,
      template_cache: cache,
      clock: fake_clock(0.0, 2.0, 4.0),
    )

    command.call
    command.call

    assert_equal 1, cache.build_calls
    assert_equal 1, cache.clone_calls
    assert_includes runner.argv_history, ["bin/rails", "db:drop"]
    assert_includes runner.argv_history, ["bin/rails", "db:create", "db:schema:load"]
  end

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

  def test_reset_state_remote_strategy_reports_schema_load_failure
    runner = FakeCommandRunner.new(
      results: {
        ["bin/rails", "db:schema:load"] => FakeResult.new(status: 1, stdout: "", stderr: "schema failed"),
      },
    )
    command = RailsAdapter::Commands::ResetState.new(
      app_root: "/tmp/demo",
      workload: "missing-index-todos",
      seed: 42,
      env_pairs: {},
      command_runner: runner,
      template_cache: FakeTemplateCache.new,
      reset_strategy: "remote",
      clock: fake_clock(0.0, 1.0),
    )

    result = command.call

    refute result.fetch("ok")
    assert_equal "reset_failed", result.fetch("error").fetch("code")
    assert_includes result.fetch("error").fetch("message"), "schema load failed"
    assert_includes result.fetch("error").fetch("message"), "schema failed"
  end

  def test_reset_state_remote_strategy_reports_seed_failure_details
    runner = FakeCommandRunner.new(
      results: {
        ["bin/rails", "runner", %(load Rails.root.join("db/seeds.rb").to_s)] => FakeResult.new(status: 1, stdout: "", stderr: "seed failed"),
      },
    )
    command = RailsAdapter::Commands::ResetState.new(
      app_root: "/tmp/demo",
      workload: "missing-index-todos",
      seed: 42,
      env_pairs: {},
      command_runner: runner,
      template_cache: FakeTemplateCache.new,
      reset_strategy: "remote",
      clock: fake_clock(0.0, 1.0),
    )

    result = command.call

    refute result.fetch("ok")
    assert_equal "reset_failed", result.fetch("error").fetch("code")
    assert_includes result.fetch("error").fetch("message"), "seed failed"
    assert_includes result.fetch("error").fetch("message"), "seed runner failed"
  end

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

  def test_reset_state_rebuilds_template_when_seed_env_changes
    runner = FakeCommandRunner.new
    cache = SeedAwareTemplateCache.new
    first_command = RailsAdapter::Commands::ResetState.new(
      app_root: "/tmp/demo",
      seed: 7,
      env_pairs: { "ROWS_PER_TABLE" => "1000", "OPEN_FRACTION" => "0.2" },
      command_runner: runner,
      template_cache: cache,
      clock: fake_clock(0.0, 2.0, 4.0),
    )
    second_command = RailsAdapter::Commands::ResetState.new(
      app_root: "/tmp/demo",
      seed: 42,
      env_pairs: { "ROWS_PER_TABLE" => "10000000", "OPEN_FRACTION" => "0.002" },
      command_runner: runner,
      template_cache: cache,
      clock: fake_clock(10.0, 12.0, 14.0),
    )

    first_command.call
    second_command.call

    assert_equal 2, cache.build_calls
    assert_equal 0, cache.clone_calls
  end

  def test_reset_state_resets_pg_stat_statements_counters
    runner = FakeCommandRunner.new
    command = RailsAdapter::Commands::ResetState.new(
      app_root: "/tmp/demo",
      seed: 42,
      env_pairs: {},
      command_runner: runner,
      template_cache: FakeTemplateCache.new(template_exists: true),
      clock: fake_clock(0.0, 1.0),
    )

    command.call

    rails_runner_calls = runner.argv_history.select { |argv| argv.first(2) == ["bin/rails", "runner"] }
    assert rails_runner_calls.any? { |argv| argv.last.include?("CREATE EXTENSION IF NOT EXISTS pg_stat_statements") }, "expected a bin/rails runner call that enables pg_stat_statements"
    assert rails_runner_calls.any? { |argv| argv.last.include?("pg_stat_statements_reset") }, "expected a bin/rails runner call that invokes pg_stat_statements_reset()"
  end

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

  def test_reset_state_does_not_embed_workload_query_id_scripts
    constant_name = [:QUERY, :IDS, :SCRIPT].join("_").to_sym
    refute RailsAdapter::Commands::ResetState.const_defined?(constant_name)
  end

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

  private

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

  def with_env(overrides)
    previous = overrides.transform_values { nil }
    overrides.each_key { |key| previous[key] = ENV[key] }
    overrides.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    previous.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end

  class SeedAwareTemplateCache < FakeTemplateCache
    def initialize
      super(template_exists: false)
      @templates = {}
    end

    def template_exists?(**kwargs)
      @templates[key(kwargs)]
    end

    def build_template(**kwargs)
      super
      @templates[key(kwargs)] = true
    end

    private

    def key(kwargs)
      [kwargs.fetch(:database_name), kwargs.fetch(:app_root), kwargs.fetch(:env_pairs).sort]
    end
  end
end
