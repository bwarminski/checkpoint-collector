# ABOUTME: Verifies the migrate command runs Rails schema setup commands.
# ABOUTME: Ensures migrate returns the reported schema version.
require_relative "test_helper"

class MigrateTest < Minitest::Test
  def test_migrate_runs_db_create_and_db_migrate
    runner = FakeCommandRunner.new(
      results: {
        ["bin/rails", "db:create", "db:migrate"] => FakeResult.new(status: 0, stdout: "", stderr: ""),
        ["bin/rails", "runner", "puts ActiveRecord::Base.connection.migration_context.current_version"] => FakeResult.new(status: 0, stdout: "20260421000000\n", stderr: ""),
      },
    )
    command = RailsAdapter::Commands::Migrate.new(app_root: "/tmp/demo", command_runner: runner)

    result = command.call

    assert result.fetch("ok")
    assert_equal "migrate", result.fetch("command")
    assert_equal "20260421000000", result.fetch("schema_version")
  end
end
