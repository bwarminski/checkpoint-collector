# ABOUTME: Verifies the stop command terminates or ignores Rails server pids safely.
# ABOUTME: Ensures stop uses kill polling and never attempts waitpid.
require_relative "test_helper"

class StopTest < Minitest::Test
  def test_stop_returns_ok_true_on_unknown_pid
    killer = FakeProcessKiller.new(kill_raises: { "TERM" => Errno::ESRCH })
    command = RailsAdapter::Commands::Stop.new(pid: 99_999, process_killer: killer, clock: fake_clock(0.0), sleeper: ->(*) {})

    result = command.call

    assert result.fetch("ok")
  end

  def test_stop_escalates_to_sigkill_after_ten_second_term_budget
    clock = fake_clock(0.0, 2.0, 4.0, 6.0, 8.0, 10.5, 11.0)
    killer = FakeProcessKiller.new(alive: true)
    command = RailsAdapter::Commands::Stop.new(pid: 12_345, process_killer: killer, clock:, sleeper: ->(*) {})

    command.call

    assert_includes killer.signals_sent, "TERM"
    assert_includes killer.signals_sent, "KILL"
  end

  def test_stop_never_calls_waitpid
    killer = FakeProcessKiller.new(dies_after_term: true)
    command = RailsAdapter::Commands::Stop.new(pid: 12_345, process_killer: killer, clock: fake_clock(0.0, 0.2), sleeper: ->(*) {})

    command.call

    assert_equal 0, killer.waitpid_calls
  end
end
