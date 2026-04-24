# ABOUTME: Verifies the prepare command checks gems and benchmark DB reachability.
# ABOUTME: Ensures prepare fails fast when bundle dependencies are missing.
require_relative "test_helper"

class PrepareTest < Minitest::Test
  def test_prepare_fails_fast_when_bundle_check_fails
    runner = FakeCommandRunner.new(
      results: {
        ["bundle", "check"] => FakeResult.new(status: 1, stdout: "", stderr: "deps missing"),
      },
    )
    command = RailsAdapter::Commands::Prepare.new(app_root: "/tmp/demo", command_runner: runner)

    result = command.call

    refute result.fetch("ok")
    assert_equal "bundle_missing", result.dig("error", "code")
    refute_includes runner.argv_history, ["bundle", "install"]
  end

  def test_prepare_checks_bundle_against_app_gemfile
    runner = FakeCommandRunner.new
    command = RailsAdapter::Commands::Prepare.new(app_root: "/tmp/demo", command_runner: runner)

    command.call

    assert_equal(
      { "BUNDLE_GEMFILE" => "/tmp/demo/Gemfile" },
      runner.env_history.first,
    )
  end
end
