# ABOUTME: Verifies the CLI resolves named workloads and delegates to the injected runner seam.
# ABOUTME: Covers top-level help/version handling and workload lookup failures.
require "open3"
require "socket"
require "rbconfig"
require "stringio"
require "tmpdir"
require "timeout"
require_relative "test_helper"

class CliTest < Minitest::Test
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

  def setup
    Load::WorkloadRegistry.clear
    Load::WorkloadRegistry.register("fixture-workload", FixtureWorkload)
  end

  def teardown
    Load::WorkloadRegistry.clear
  end

  def test_run_command_uses_runner_factory_and_calls_run
    factory = FakeRunnerFactory.new(exit_code: 0)

    status = run_bin_load(
      "run",
      "--workload",
      "fixture-workload",
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
    assert_equal 5.0, factory.calls.first.fetch(:metrics_interval_seconds)
    assert_equal 1, factory.runners.first.run_calls
  end

  def test_run_command_passes_metrics_interval_override
    factory = FakeRunnerFactory.new(exit_code: 0)

    status = run_bin_load(
      "run",
      "--workload",
      "fixture-workload",
      "--adapter",
      "fake-adapter",
      "--app-root",
      "/tmp/demo",
      "--metrics-interval-seconds",
      "2.5",
      runner: factory,
    )

    assert_equal 0, status
    assert_equal 2.5, factory.calls.first.fetch(:metrics_interval_seconds)
  end

  def test_run_command_normalizes_none_readiness_path_to_nil
    factory = FakeRunnerFactory.new(exit_code: 0)

    status = run_bin_load(
      "run",
      "--workload",
      "fixture-workload",
      "--adapter",
      "fake-adapter",
      "--app-root",
      "/tmp/demo",
      "--readiness-path",
      "none",
      runner: factory,
    )

    assert_equal 0, status
    assert_nil factory.calls.first.fetch(:readiness_path)
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

  def test_bin_load_run_dispatches_into_cli
    _stdout, stderr, status = capture_bin_load(
      "run",
      "--workload",
      "missing-index-todos",
      "--adapter",
      "/nonexistent-adapter",
      "--app-root",
      "/tmp/demo",
    )

    refute status.success?
    refute_includes stderr, "Usage: bin/load"
    assert_includes stderr, "/nonexistent-adapter"
  end

  def test_run_command_exits_zero_on_successful_run
    factory = FakeRunnerFactory.new(exit_code: 0)
    status = run_bin_load(
      "run",
      "--workload",
      "fixture-workload",
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
      "fixture-workload",
      "--adapter",
      "fake-adapter",
      "--app-root",
      "/tmp/demo",
      runner: factory,
    )

    assert_equal 1, status
    assert_equal 1, factory.runners.first.run_calls
  end

  def test_run_command_exits_two_when_workload_name_is_unknown
    status = run_bin_load(
      "run",
      "--workload",
      "unknown-workload",
      "--adapter",
      "fake-adapter",
      "--app-root",
      "/tmp/demo",
    )

    assert_equal 2, status
  end

  def test_run_command_exits_two_when_workload_file_is_missing
    status = run_bin_load(
      "run",
      "--workload",
      "missing-file",
      "--adapter",
      "fake-adapter",
      "--app-root",
      "/tmp/demo",
    )

    assert_equal 2, status
  end

  def test_run_command_exits_three_when_no_successful_requests
    factory = FakeRunnerFactory.new(exit_code: 3)
    status = run_bin_load(
      "run",
      "--workload",
      "fixture-workload",
      "--adapter",
      "fake-adapter",
      "--app-root",
      "/tmp/demo",
      runner: factory,
    )

    assert_equal 3, status
    assert_equal 1, factory.runners.first.run_calls
  end

  def test_bin_load_handles_sigterm_and_marks_run_aborted
    Dir.mktmpdir do |dir|
      runs_dir = File.join(dir, "runs")
      adapter_path = write_fake_adapter(dir)
      stdout_path = File.join(dir, "stdout.log")
      stderr_path = File.join(dir, "stderr.log")
      with_http_server(3999) do
        pid = Process.spawn(
          RbConfig.ruby,
          bin_load_path,
          "run",
          "--workload",
          "missing-index-todos",
          "--adapter",
          adapter_path,
          "--app-root",
          dir,
          "--runs-dir",
          runs_dir,
          "--readiness-path",
          "none",
          "--startup-grace-seconds",
          "0",
          out: stdout_path,
          err: stderr_path,
        )

        run_path = wait_for_run_start(runs_dir)
        Process.kill("TERM", pid)
        _pid, status = Process.wait2(pid)

        assert_equal 0, status.exitstatus
        payload = JSON.parse(File.read(run_path))
        assert_equal true, payload.fetch("outcome").fetch("aborted")
      end
    end
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

  def write_fake_adapter(dir)
    path = File.join(dir, "fake-adapter")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      require "json"

      argv = ARGV.dup
      argv.shift if argv.first == "--json"
      command = argv.shift
      payload = case command
      when "describe"
        {"ok" => true, "command" => "describe", "name" => "fake-adapter", "framework" => "ruby", "runtime" => RUBY_VERSION}
      when "prepare"
        {"ok" => true, "command" => "prepare"}
      when "reset-state"
        {"ok" => true, "command" => "reset-state"}
      when "start"
        {"ok" => true, "command" => "start", "pid" => Process.pid, "base_url" => "http://127.0.0.1:3999"}
      when "stop"
        {"ok" => true, "command" => "stop"}
      else
        {"ok" => false, "command" => command, "error" => {"code" => "unknown", "message" => "unknown", "details" => {}}}
      end

      puts(JSON.generate(payload))
      exit(payload.fetch("ok") ? 0 : 1)
    RUBY
    File.chmod(0o755, path)
    path
  end

  def wait_for_run_start(runs_dir)
    Timeout.timeout(10) do
      loop do
        run_path = Dir[File.join(runs_dir, "*", "run.json")].max_by { |path| File.mtime(path) }
        if run_path && File.exist?(run_path)
          payload = JSON.parse(File.read(run_path))
          return run_path if payload.dig("window", "start_ts")
        end

        sleep 0.05
      end
    end
  end

  def with_http_server(port)
    server = TCPServer.new("127.0.0.1", port)
    stop_reader, stop_writer = IO.pipe
    thread = Thread.new do
      loop do
        ready = IO.select([server, stop_reader])
        next unless ready

        if ready.first.include?(stop_reader)
          break
        end

        client = server.accept
        begin
          client.readpartial(1024)
          client.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
        ensure
          client.close
        end
      rescue EOFError, IOError
      end
    end
    yield
  ensure
    stop_writer&.write("stop")
    stop_writer&.close
    server&.close
    thread&.join(1) || thread&.kill
    stop_reader&.close
  end

  def run_bin_load(*argv, runner: FakeRunnerFactory.new(exit_code: 0))
    Load::CLI.new(
      argv:,
      version: "test-version",
      runner:,
      stdout: StringIO.new,
      stderr: StringIO.new,
    ).run
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
