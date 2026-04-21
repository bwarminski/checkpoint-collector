# ABOUTME: Verifies the adapter client passes the expected argv to the adapter binary.
# ABOUTME: Covers scale env propagation and seed forwarding for reset-state.
require_relative "test_helper"

class AdapterClientTest < Minitest::Test
  def test_reset_state_passes_seed_and_scale_env
    capture = FakeCapture3.new(stdout: %({"ok":true,"command":"reset-state"}))
    client = Load::AdapterClient.new(adapter_bin: "adapters/rails/bin/bench-adapter", capture3: capture)

    client.reset_state(
      app_root: "/tmp/app",
      scale: Load::Scale.new(rows_per_table: 10_000_000, open_fraction: 0.002, seed: 42),
    )

    assert_equal ["reset-state", "--app-root", "/tmp/app", "--seed", "42", "--env", "ROWS_PER_TABLE=10000000", "--env", "OPEN_FRACTION=0.002"], capture.argv
  end

  class FakeCapture3
    attr_reader :argv

    def initialize(stdout:)
      @stdout = stdout
      @stderr = ""
    end

    def call(*argv)
      @argv = argv.drop(1)
      [@stdout, @stderr, Struct.new(:success?).new(true)]
    end
  end
end
