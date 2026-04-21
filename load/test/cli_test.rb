# ABOUTME: Verifies the CLI loads workloads and delegates to the injected runner seam.
# ABOUTME: Covers missing workloads and workloads that do not define a Load::Workload subclass.
require "tempfile"
require "tmpdir"
require_relative "test_helper"

class CliTest < Minitest::Test
  def test_run_command_exits_zero_on_successful_run
    status = run_bin_load(
      "run",
      "--workload",
      fixture_workload_path,
      "--adapter",
      "fake-adapter",
      "--app-root",
      "/tmp/demo",
      runner: FakeRunner.new(exit_code: 0),
    )

    assert_equal 0, status
  end

  def test_run_command_exits_one_on_adapter_error
    status = run_bin_load(
      "run",
      "--workload",
      fixture_workload_path,
      "--adapter",
      "fake-adapter",
      "--app-root",
      "/tmp/demo",
      runner: FakeRunner.new(exit_code: 1),
    )

    assert_equal 1, status
  end

  def test_run_command_exits_two_when_workload_file_missing
    status = run_bin_load(
      "run",
      "--workload",
      "/nonexistent.rb",
      "--adapter",
      "fake-adapter",
      "--app-root",
      "/tmp/demo",
    )

    assert_equal 2, status
  end

  def test_run_command_exits_two_when_workload_file_defines_no_subclass
    Dir.mktmpdir do |dir|
      path = File.join(dir, "bad_workload.rb")
      File.write(path, "# no Load::Workload subclass\n")

      status = run_bin_load(
        "run",
        "--workload",
        path,
        "--adapter",
        "fake-adapter",
        "--app-root",
        "/tmp/demo",
      )

      assert_equal 2, status
    end
  end

  def test_run_command_exits_three_when_no_successful_requests
    status = run_bin_load(
      "run",
      "--workload",
      fixture_workload_path,
      "--adapter",
      "fake-adapter",
      "--app-root",
      "/tmp/demo",
      runner: FakeRunner.new(exit_code: 3),
    )

    assert_equal 3, status
  end

  private

  def fixture_workload_path
    @fixture_workload_path ||= begin
      dir = Dir.mktmpdir
      path = File.join(dir, "fixture_workload.rb")
      File.write(path, <<~RUBY)
        class FixtureWorkload < Load::Workload
          def name
            "fixture-workload"
          end

          def scale
            Load::Scale.new(rows_per_table: 1, open_fraction: 0.0, seed: 42)
          end

          def actions
            []
          end

          def load_plan
            Load::LoadPlan.new(workers: 1, duration_seconds: 0, rate_limit: :unlimited, seed: 42)
          end
        end
      RUBY
      path
    end
  end

  def run_bin_load(*argv, runner: FakeRunner.new(exit_code: 0))
    Load::CLI.new(argv:, runner:).run
  end

  class FakeRunner
    attr_reader :calls

    def initialize(exit_code:)
      @exit_code = exit_code
      @calls = []
    end

    def call(**kwargs)
      @calls << kwargs
      @exit_code
    end
  end
end
