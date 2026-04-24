# ABOUTME: Verifies the load-dataset command runs Rails seeds with benchmark env.
# ABOUTME: Ensures workload scale fields are propagated into subprocess env vars.
require_relative "test_helper"

class LoadDatasetTest < Minitest::Test
  def test_load_dataset_runs_rails_runner_with_scale_env
    runner = FakeCommandRunner.new
    command = RailsAdapter::Commands::LoadDataset.new(
      app_root: "/tmp/demo",
      workload: "missing-index-todos",
      seed: 42,
      env_pairs: { "ROWS_PER_TABLE" => "10000000", "OPEN_FRACTION" => "0.002" },
      command_runner: runner,
      clock: fake_clock(0.0, 1.25),
    )

    result = command.call

    assert_equal "load-dataset", result.fetch("command")
    assert_includes runner.env.fetch("SEED"), "42"
    assert_equal "1", runner.env.fetch("SECRET_KEY_BASE_DUMMY")
    assert_includes runner.argv, %(load Rails.root.join("db/seeds.rb").to_s)
  end
end
