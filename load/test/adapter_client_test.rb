# ABOUTME: Verifies the adapter client passes the expected argv to the adapter binary.
# ABOUTME: Covers scale env propagation and seed forwarding for reset-state.
require_relative "test_helper"

class AdapterClientTest < Minitest::Test
  def test_reset_state_passes_seed_and_scale_env
    capture = FakeCapture3.new(stdout: %({"ok":true,"command":"reset-state"}))
    client = Load::AdapterClient.new(adapter_bin: "adapters/rails/bin/bench-adapter", capture3: capture)

    client.reset_state(
      app_root: "/tmp/app",
      workload: "missing-index-todos",
      scale: Load::Scale.new(rows_per_table: 10_000_000, open_fraction: 0.002, seed: 42),
    )

    assert_equal ["--json", "reset-state", "--app-root", "/tmp/app", "--workload", "missing-index-todos", "--seed", "42", "--env", "ROWS_PER_TABLE=10000000", "--env", "OPEN_FRACTION=0.002"], capture.argv
  end

  def test_adapter_client_logs_successful_invokes_to_run_record
    capture = FakeCapture3.new(stdout: %({"ok":true,"command":"describe"}), exit_status: 0)
    run_record = FakeRunRecord.new
    client = Load::AdapterClient.new(
      adapter_bin: "adapters/rails/bin/bench-adapter",
      capture3: capture,
      run_record:,
      clock: FakeClock.new([Time.utc(2026, 4, 22, 2, 30, 0), Time.utc(2026, 4, 22, 2, 30, 1)]),
    )

    client.describe

    assert_equal 1, run_record.lines.length
    line = run_record.lines.first
    assert_equal "describe", line.fetch(:command)
    assert_equal Time.utc(2026, 4, 22, 2, 30, 0), line.fetch(:ts)
    assert_equal [], line.fetch(:args)
    assert_equal 0, line.fetch(:exit_code)
    assert_equal 1000, line.fetch(:duration_ms)
    assert_equal true, line.fetch(:stdout_json).fetch("ok")
    assert_equal "", line.fetch(:stderr)
  end

  def test_adapter_client_logs_error_invokes_before_raising
    capture = FakeCapture3.new(stdout: %({"ok":false,"command":"stop"}), stderr: "boom", exit_status: 1)
    run_record = FakeRunRecord.new
    client = Load::AdapterClient.new(
      adapter_bin: "adapters/rails/bin/bench-adapter",
      capture3: capture,
      run_record:,
      clock: FakeClock.new([Time.utc(2026, 4, 22, 2, 31, 0), Time.utc(2026, 4, 22, 2, 31, 1)]),
    )

    error = assert_raises(Load::AdapterClient::AdapterError) { client.stop(pid: 123) }

    assert_equal "boom", error.message
    assert_equal 1, run_record.lines.length
    line = run_record.lines.first
    assert_equal "stop", line.fetch(:command)
    assert_equal Time.utc(2026, 4, 22, 2, 31, 0), line.fetch(:ts)
    assert_equal ["--pid", "123"], line.fetch(:args)
    assert_equal 1, line.fetch(:exit_code)
    assert_equal 1000, line.fetch(:duration_ms)
    assert_equal "boom", line.fetch(:stderr)
    assert_equal false, line.fetch(:stdout_json).fetch("ok")
  end

  def test_describe_raises_adapter_error_on_malformed_json
    capture = FakeCapture3.new(stdout: "not json")
    client = Load::AdapterClient.new(adapter_bin: "adapters/rails/bin/bench-adapter", capture3: capture)

    error = assert_raises(Load::AdapterClient::AdapterError) { client.describe }

    assert_includes error.message, "unexpected token"
  end

  class FakeCapture3
    attr_reader :argv

    def initialize(stdout:, stderr: "", exit_status: 0)
      @stdout = stdout
      @stderr = stderr
      @exit_status = exit_status
    end

    def call(*argv)
      @argv = argv.drop(1)
      [@stdout, @stderr, FakeStatus.new(@exit_status)]
    end
  end

  FakeStatus = Struct.new(:exitstatus) do
    def success?
      exitstatus.zero?
    end
  end

  class FakeRunRecord
    attr_reader :lines

    def initialize
      @lines = []
    end

    def append_adapter_command(payload)
      @lines << payload
    end
  end

  class FakeClock
    def initialize(values)
      @values = values.dup
    end

    def call
      @values.shift
    end
  end
end
