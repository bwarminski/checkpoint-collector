# ABOUTME: Verifies the start command spawns Rails on an adapter-selected port.
# ABOUTME: Ensures port exhaustion is reported and Process.detach is never used.
require_relative "test_helper"

class StartTest < Minitest::Test
  def test_start_returns_port_exhausted_when_all_ports_busy
    port_finder = FakePortFinder.new(all_busy: true)
    command = RailsAdapter::Commands::Start.new(app_root: "/tmp/demo", port_finder:, spawner: FakeSpawner.new)

    result = command.call

    refute result.fetch("ok")
    assert_equal "port_exhausted", result.dig("error", "code")
  end

  def test_start_does_not_call_process_detach
    spawner = FakeSpawner.new
    command = RailsAdapter::Commands::Start.new(app_root: "/tmp/demo", port_finder: FakePortFinder.new(port: 3000), spawner:)

    command.call

    assert_equal 0, spawner.detach_calls
  end
end
