# ABOUTME: Verifies the CLI loads workloads and delegates to the injected runner seam.
# ABOUTME: Covers missing workloads and workloads that do not define a Load::Workload subclass.
require "open3"
require "rbconfig"
require "tempfile"
require "tmpdir"
require_relative "test_helper"

class CliTest < Minitest::Test
  def test_run_command_uses_runner_factory_and_calls_run
    factory = FakeRunnerFactory.new(exit_code: 0)

    status = run_bin_load(
      "run",
      "--workload",
      fixture_workload_path,
      "--adapter",
      "fake-adapter",
      "--app-root",
      "/tmp/demo",
      runner: factory,
    )

    assert_equal 0, status
    assert_equal 1, factory.calls.length
    assert_equal "fixture-workload", factory.calls.first.fetch(:workload).name
    assert_equal "fake-adapter", factory.calls.first.fetch(:adapter_bin)
    assert_equal "/tmp/demo", factory.calls.first.fetch(:app_root)
    assert_equal 1, factory.runners.first.run_calls
  end

  def test_bin_load_help_prints_usage_and_exits_zero
    stdout, stderr, status = capture_bin_load("--help")

    assert status.success?
    assert_includes stdout, "Usage: bin/load"
    assert_equal "", stderr
  end

  def test_bin_load_version_prints_version_and_exits_zero
    stdout, stderr, status = capture_bin_load("--version")

    assert status.success?
    assert_equal File.read(version_path).strip, stdout.strip
    assert_equal "", stderr
  end

  def test_run_command_exits_zero_on_successful_run
    factory = FakeRunnerFactory.new(exit_code: 0)
    status = run_bin_load(
      "run",
      "--workload",
      fixture_workload_path,
      "--adapter",
      "fake-adapter",
      "--app-root",
      "/tmp/demo",
      runner: factory,
    )

    assert_equal 0, status
    assert_equal 1, factory.runners.first.run_calls
  end

  def test_run_command_exits_one_on_adapter_error
    factory = FakeRunnerFactory.new(exit_code: 1)
    status = run_bin_load(
      "run",
      "--workload",
      fixture_workload_path,
      "--adapter",
      "fake-adapter",
      "--app-root",
      "/tmp/demo",
      runner: factory,
    )

    assert_equal 1, status
    assert_equal 1, factory.runners.first.run_calls
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
    factory = FakeRunnerFactory.new(exit_code: 3)
    status = run_bin_load(
      "run",
      "--workload",
      fixture_workload_path,
      "--adapter",
      "fake-adapter",
      "--app-root",
      "/tmp/demo",
      runner: factory,
    )

    assert_equal 3, status
    assert_equal 1, factory.runners.first.run_calls
  end

  private

  def capture_bin_load(*argv)
    Open3.capture3(RbConfig.ruby, bin_load_path, *argv)
  end

  def bin_load_path
    @bin_load_path ||= File.expand_path("../../bin/load", __dir__)
  end

  def version_path
    @version_path ||= File.expand_path("../../VERSION", __dir__)
  end

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

  def run_bin_load(*argv, runner: FakeRunnerFactory.new(exit_code: 0))
    Load::CLI.new(argv:, runner:).run
  end

  class FakeRunnerFactory
    attr_reader :calls, :runners

    def initialize(exit_code:)
      @exit_code = exit_code
      @calls = []
      @runners = []
    end

    def call(**kwargs)
      @calls << kwargs
      runner = FakeRunner.new(@exit_code)
      @runners << runner
      runner
    end
  end

  class FakeRunner
    attr_reader :run_calls

    def initialize(exit_code)
      @exit_code = exit_code
      @run_calls = 0
    end

    def run
      @run_calls += 1
      @exit_code
    end
  end
end
