# ABOUTME: Verifies the CLI resolves named workloads and delegates to the injected runner seam.
# ABOUTME: Covers top-level help/version handling and workload lookup failures.
require "open3"
require "socket"
require "rbconfig"
require "stringio"
require "tmpdir"
require "timeout"
require "fileutils"
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

  class MissingIndexTodosWorkload < FixtureWorkload
    def name
      "missing-index-todos"
    end
  end

  def setup
    Load::WorkloadRegistry.clear
    Load::WorkloadRegistry.register("fixture-workload", FixtureWorkload)
    Load::WorkloadRegistry.register("missing-index-todos", MissingIndexTodosWorkload)
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
      runner_factory: factory,
    )

    assert_equal 0, status
    assert_equal 1, factory.calls.length
    assert_equal :finite, factory.calls.first.fetch(:mode)
    assert_equal "fixture-workload", factory.calls.first.fetch(:workload).name
    assert_equal "fake-adapter", factory.calls.first.fetch(:adapter_bin)
    assert_equal "/tmp/demo", factory.calls.first.fetch(:app_root)
    assert_equal 5.0, factory.calls.first.fetch(:metrics_interval_seconds)
    assert_equal 1, factory.runners.first.run_calls
  end

  def test_default_runner_factory_builds_a_fixture_verifier_for_finite_runs
    cli = Load::CLI.new(
      argv: [],
      version: "0.3.0",
      stdout: StringIO.new,
      stderr: StringIO.new,
    )

    original_database_url = ENV["DATABASE_URL"]
    ENV["DATABASE_URL"] = "postgres://example.test/checkpoint"

    verifier_factory = cli.send(:default_verifier_factory)
    verifier = verifier_factory.call(
      workload_name: "missing-index-todos",
      adapter_bin: "adapters/rails/bin/bench-adapter",
      app_root: "/tmp/demo",
      stdout: StringIO.new,
      stderr: StringIO.new,
    )

    assert_instance_of Load::FixtureVerifier, verifier
    assert_equal "missing-index-todos", verifier.instance_variable_get(:@workload_name)

    captured_runner_kwargs = nil
    Load::Runner.stub(:new, ->(**kwargs) do
      captured_runner_kwargs = kwargs
      Object.new
    end) do
      cli.send(:default_runner_factory).call(
        workload: MissingIndexTodosWorkload.new,
        mode: :finite,
        adapter_bin: "adapters/rails/bin/bench-adapter",
        app_root: "/tmp/demo",
        runs_dir: Dir.mktmpdir,
        readiness_path: "/up",
        startup_grace_seconds: 15.0,
        metrics_interval_seconds: 5.0,
        stop_flag: Load::Runner::InternalStopFlag.new,
        stdout: StringIO.new,
        stderr: StringIO.new,
      )
    end

    assert_instance_of Load::FixtureVerifier, captured_runner_kwargs.fetch(:verifier)
    assert_equal "missing-index-todos", captured_runner_kwargs.fetch(:verifier).instance_variable_get(:@workload_name)
  ensure
    ENV["DATABASE_URL"] = original_database_url
  end

  def test_default_runner_factory_builds_a_fixture_verifier_for_missing_index_todos_soak_runs
    cli = Load::CLI.new(
      argv: [],
      version: "0.3.0",
      stdout: StringIO.new,
      stderr: StringIO.new,
    )

    original_database_url = ENV["DATABASE_URL"]
    ENV["DATABASE_URL"] = "postgres://example.test/checkpoint"

    captured_runner_kwargs = nil
    Load::Runner.stub(:new, ->(**kwargs) do
      captured_runner_kwargs = kwargs
      Object.new
    end) do
      cli.send(:default_runner_factory).call(
        workload: MissingIndexTodosWorkload.new,
        mode: :continuous,
        adapter_bin: "adapters/rails/bin/bench-adapter",
        app_root: "/tmp/demo",
        runs_dir: Dir.mktmpdir,
        readiness_path: "/up",
        startup_grace_seconds: 15.0,
        metrics_interval_seconds: 5.0,
        stop_flag: Load::Runner::InternalStopFlag.new,
        stdout: StringIO.new,
        stderr: StringIO.new,
      )
    end

    assert_instance_of Load::FixtureVerifier, captured_runner_kwargs.fetch(:verifier)
    assert_equal "missing-index-todos", captured_runner_kwargs.fetch(:verifier).instance_variable_get(:@workload_name)
    assert_equal :continuous, captured_runner_kwargs.fetch(:mode)
  ensure
    ENV["DATABASE_URL"] = original_database_url
  end

  def test_default_runner_factory_skips_fixture_verifier_for_unrelated_workloads
    cli = Load::CLI.new(
      argv: [],
      version: "0.3.0",
      stdout: StringIO.new,
      stderr: StringIO.new,
    )

    original_database_url = ENV["DATABASE_URL"]
    ENV.delete("DATABASE_URL")

    captured_runner_kwargs = nil
    Load::Runner.stub(:new, ->(**kwargs) do
      captured_runner_kwargs = kwargs
      Object.new
    end) do
      cli.send(:default_runner_factory).call(
        workload: FixtureWorkload.new,
        mode: :finite,
        adapter_bin: "adapters/rails/bin/bench-adapter",
        app_root: "/tmp/demo",
        runs_dir: Dir.mktmpdir,
        readiness_path: "/up",
        startup_grace_seconds: 15.0,
        metrics_interval_seconds: 5.0,
        stop_flag: Load::Runner::InternalStopFlag.new,
        stdout: StringIO.new,
        stderr: StringIO.new,
      )
    end

    assert_nil captured_runner_kwargs.fetch(:verifier)
  ensure
    ENV["DATABASE_URL"] = original_database_url
  end

  def test_cli_runs_verify_fixture_command
    Dir.mktmpdir do |dir|
      with_http_server do |port|
        adapter_path = write_fake_adapter(dir, port:)
        verifier_calls = []
        verifier = Object.new
        verifier.define_singleton_method(:call) do |base_url:|
          verifier_calls << base_url
          Load::ExitCodes::SUCCESS
        end

        cli = Load::CLI.new(
          argv: [
            "verify-fixture",
            "--workload",
            "missing-index-todos",
            "--adapter",
            adapter_path,
            "--app-root",
            dir,
          ],
          version: "0.3.0",
          verifier_factory: ->(**kwargs) do
            assert_equal "missing-index-todos", kwargs.fetch(:workload_name)
            verifier
          end,
          stdout: StringIO.new,
          stderr: StringIO.new,
        )

        assert_equal Load::ExitCodes::SUCCESS, cli.run
        assert_equal ["http://127.0.0.1:#{port}"], verifier_calls
      end
    end
  end

  def test_cli_runs_verify_fixture_command_with_runner_only_flag_rejected
    stdout = StringIO.new
    stderr = StringIO.new

    cli = Load::CLI.new(
      argv: [
        "verify-fixture",
        "--workload",
        "missing-index-todos",
        "--adapter",
        "adapters/rails/bin/bench-adapter",
        "--app-root",
        "/tmp/demo",
        "--runs-dir",
        "runs",
      ],
      version: "0.3.0",
      stdout:,
      stderr:,
    )

    assert_equal Load::ExitCodes::USAGE_ERROR, cli.run
    assert_includes stderr.string, "--runs-dir"
    assert_includes stderr.string, "Usage: bin/load"
  end

  def test_cli_runs_verify_fixture_command_without_factory_treating_setup_failures_as_adapter_errors
    stdout = StringIO.new
    stderr = StringIO.new

    cli = Load::CLI.new(
      argv: [
        "verify-fixture",
        "--workload",
        "missing-index-todos",
        "--adapter",
        "adapters/rails/bin/bench-adapter",
        "--app-root",
        "/tmp/demo",
      ],
      version: "0.3.0",
      stdout:,
      stderr:,
    )

    assert_equal Load::ExitCodes::ADAPTER_ERROR, cli.run
    assert_includes stderr.string, "missing DATABASE_URL for fixture verification"
    refute_includes stderr.string, "Usage: bin/load"
  end

  def test_cli_runs_verify_fixture_command_without_treating_verification_failure_as_usage_error
    Dir.mktmpdir do |dir|
      with_http_server do |port|
        stdout = StringIO.new
        stderr = StringIO.new
        verifier = Object.new
        verifier.define_singleton_method(:call) do |base_url:|
          raise "missing base_url" if base_url.nil?
          raise Load::FixtureVerifier::VerificationError, "fixture verification failed for /api/todos/counts: expected at least 2 count calls"
        end

        cli = Load::CLI.new(
          argv: [
            "verify-fixture",
            "--workload",
            "missing-index-todos",
            "--adapter",
            write_fake_adapter(dir, port:),
            "--app-root",
            dir,
          ],
          version: "0.3.0",
          verifier_factory: ->(**) { verifier },
          stdout:,
          stderr:,
        )

        assert_equal Load::ExitCodes::ADAPTER_ERROR, cli.run
        assert_includes stderr.string, "fixture verification failed for /api/todos/counts"
        refute_includes stderr.string, "Usage: bin/load"
      end
    end
  end

  def test_cli_verify_fixture_starts_adapter_probes_readiness_calls_verifier_and_stops_adapter
    Dir.mktmpdir do |dir|
      with_http_server do |port|
        adapter_log_path = File.join(dir, "adapter.log")
        adapter_path = write_fake_adapter(dir, port:, log_path: adapter_log_path)
        verifier_calls = []
        verifier = Object.new
        verifier.define_singleton_method(:call) do |base_url:|
          verifier_calls << base_url
          Load::ExitCodes::SUCCESS
        end

        status = Load::CLI.new(
          argv: [
            "verify-fixture",
            "--workload",
            "missing-index-todos",
            "--adapter",
            adapter_path,
            "--app-root",
            dir,
          ],
          version: "0.3.0",
          verifier_factory: ->(**) { verifier },
          stdout: StringIO.new,
          stderr: StringIO.new,
        ).run

        assert_equal Load::ExitCodes::SUCCESS, status
        assert_equal ["http://127.0.0.1:#{port}"], verifier_calls
        assert_equal ["describe", "prepare", "reset-state", "start", "stop"], File.readlines(adapter_log_path, chomp: true)
      end
    end
  end

  def test_cli_runs_soak_command
    runner_calls = []
    runner = Object.new
    runner.define_singleton_method(:run) { Load::ExitCodes::SUCCESS }

    cli = Load::CLI.new(
      argv: [
        "soak",
        "--workload",
        "missing-index-todos",
        "--adapter",
        "adapters/rails/bin/bench-adapter",
        "--app-root",
        "/tmp/demo",
      ],
      version: "0.3.0",
      runner_factory: ->(**kwargs) do
        runner_calls << kwargs
        runner
      end,
      stdout: StringIO.new,
      stderr: StringIO.new,
    )

    assert_equal Load::ExitCodes::SUCCESS, cli.run
    assert_equal 1, runner_calls.length
    assert_equal :continuous, runner_calls.first.fetch(:mode)
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
      runner_factory: factory,
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
      runner_factory: factory,
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
    with_database_url do
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
  end

  def test_bin_load_verify_fixture_with_missing_database_url_exits_adapter_error_without_usage
    stdout, stderr, status = capture_bin_load_with_env(
      { "DATABASE_URL" => nil },
      "verify-fixture",
      "--workload",
      "missing-index-todos",
      "--adapter",
      "/nonexistent-adapter",
      "--app-root",
      "/tmp/demo",
    )

    refute status.success?
    assert_equal Load::ExitCodes::ADAPTER_ERROR, status.exitstatus
    assert_equal "", stdout
    assert_includes stderr, "missing DATABASE_URL for fixture verification"
    refute_includes stderr, "Usage: bin/load"
  end

  def test_bin_load_soak_missing_index_todos_exercises_real_verifier_wiring
    Dir.mktmpdir do |dir|
      with_http_server do |port|
        adapter_path = write_fake_adapter(dir, port:)

        stdout, stderr, status = Timeout.timeout(5) do
          capture_bin_load_with_env(
            { "DATABASE_URL" => nil },
            "soak",
            "--workload",
            "missing-index-todos",
            "--adapter",
            adapter_path,
            "--app-root",
            dir,
            "--readiness-path",
            "none",
            "--startup-grace-seconds",
            "0",
          )
        end

        refute status.success?
        assert_equal Load::ExitCodes::ADAPTER_ERROR, status.exitstatus
        assert_equal "", stdout
        assert_includes stderr, "missing DATABASE_URL for fixture verification"
        refute_includes stderr, "Usage: bin/load"
      end
    end
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
      runner_factory: factory,
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
      runner_factory: factory,
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
      runner_factory: factory,
    )

    assert_equal 3, status
    assert_equal 1, factory.runners.first.run_calls
  end

  def test_bin_load_handles_sigterm_and_marks_soak_run_aborted
    with_temporary_cli_workload("signal-fixtureless") do |workload_name|
      Dir.mktmpdir do |dir|
        runs_dir = File.join(dir, "runs")
        stdout_path = File.join(dir, "stdout.log")
        stderr_path = File.join(dir, "stderr.log")
        with_http_server do |port|
          adapter_path = write_fake_adapter(dir, port:)
          pid = Process.spawn(
            { "DATABASE_URL" => "postgres://example.test/checkpoint" },
            RbConfig.ruby,
            bin_load_path,
            "soak",
            "--workload",
            workload_name,
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
  end

  private

  def capture_bin_load(*argv)
    Open3.capture3(RbConfig.ruby, bin_load_path, *argv)
  end

  def capture_bin_load_with_env(env, *argv)
    Open3.capture3(env, RbConfig.ruby, bin_load_path, *argv)
  end

  def bin_load_path
    @bin_load_path ||= File.expand_path("../../bin/load", __dir__)
  end

  def version_path
    @version_path ||= File.expand_path("../../VERSION", __dir__)
  end

  def write_fake_adapter(dir, port: 3999, log_path: nil)
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
        {"ok" => true, "command" => "start", "pid" => Process.pid, "base_url" => "http://127.0.0.1:#{port}"}
      when "stop"
        {"ok" => true, "command" => "stop"}
      else
        {"ok" => false, "command" => command, "error" => {"code" => "unknown", "message" => "unknown", "details" => {}}}
      end

      File.open("#{log_path}", "a") { |file| file.puts(command) } if #{!log_path.nil?}

      puts(JSON.generate(payload))
      exit(payload.fetch("ok") ? 0 : 1)
    RUBY
    File.chmod(0o755, path)
    path
  end

  def wait_for_run_start(runs_dir)
    Timeout.timeout(30) do
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

  def with_http_server
    server = TCPServer.new("127.0.0.1", 0)
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
    yield server.local_address.ip_port
  ensure
    stop_writer&.write("stop")
    stop_writer&.close
    server&.close
    thread&.join(1) || thread&.kill
    stop_reader&.close
  end

  def with_database_url
    original_database_url = ENV["DATABASE_URL"]
    ENV["DATABASE_URL"] = "postgres://example.test/checkpoint"
    yield
  ensure
    ENV["DATABASE_URL"] = original_database_url
  end

  def with_temporary_cli_workload(name)
    directory = File.expand_path("../../workloads/#{name.tr("-", "_")}", __dir__)
    path = File.join(directory, "workload.rb")
    FileUtils.mkdir_p(directory)
    File.write(path, <<~RUBY)
      # ABOUTME: Defines a temporary workload for the CLI subprocess signal test.
      # ABOUTME: Issues simple GET requests so soak mode can start without fixture verification.
      require_relative "../../load/lib/load"

      module Load
        module Workloads
          module SignalFixtureless
            class Workload < Load::Workload
              def name
                "#{name}"
              end

              def scale
                Load::Scale.new(rows_per_table: 1, open_fraction: 0.0, seed: 42)
              end

              def actions
                [Load::ActionEntry.new(Action, 1)]
              end

              def load_plan
                Load::LoadPlan.new(workers: 1, duration_seconds: 60, rate_limit: :unlimited, seed: 42)
              end
            end

            class Action < Load::Action
              def name
                :ping
              end

              def call
                client.get("/up")
              end
            end
          end
        end
      end

      Load::WorkloadRegistry.register("#{name}", Load::Workloads::SignalFixtureless::Workload)
    RUBY

    yield name
  ensure
    FileUtils.rm_rf(directory) if directory
  end

  def run_bin_load(*argv, runner_factory: FakeRunnerFactory.new(exit_code: 0))
    Load::CLI.new(
      argv:,
      version: "test-version",
      runner_factory:,
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
