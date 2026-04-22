# ABOUTME: Verifies the reset-state command rebuilds or clones a template database.
# ABOUTME: Ensures reset-state also clears pg_stat_statements counters after seeding.
require_relative "test_helper"

class ResetStateTest < Minitest::Test
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
    assert_includes runner.argv_history, ["bin/rails", "db:drop", "db:create", "db:schema:load"]
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
end
