# ABOUTME: Verifies fixture command parsing and dispatch without depending on fixture code.
# ABOUTME: Exercises `all` ordering and invalid-verb usage handling before implementation exists.
require "minitest/autorun"
require "stringio"
require_relative "../../lib/fixtures/command"

class FixtureCommandTest < Minitest::Test
  def test_all_runs_reset_drive_and_assert_in_order
    events = []
    fake_manifest = Struct.new(:seconds, :concurrency, :rate).new(60, 16, "unlimited")
    registry = {
      ["missing-index", "reset"] => ->(**) { events << :reset },
      ["missing-index", "drive"] => ->(**) { events << :drive },
      ["missing-index", "assert"] => ->(**) { events << :assert },
    }

    Fixtures::Command.new(
      argv: ["missing-index", "all", "--seconds", "15", "--base-url", "http://localhost:3000"],
      registry: registry,
      manifest_loader: Class.new { define_singleton_method(:load) { |_| fake_manifest } },
      stdout: StringIO.new,
      stderr: StringIO.new,
    ).run

    assert_equal [:reset, :drive, :assert], events
  end

  def test_invalid_verb_prints_usage_and_returns_non_zero
    stdout = StringIO.new
    stderr = StringIO.new

    exit_code = Fixtures::Command.new(
      argv: ["missing-index", "explode"],
      registry: {},
      manifest_loader: Class.new { define_singleton_method(:load) { |_| Struct.new(:seconds, :concurrency, :rate).new(60, 16, "unlimited") } },
      stdout: stdout,
      stderr: stderr,
    ).run

    assert_equal 1, exit_code
    assert_includes stderr.string, "Usage:"
  end

  def test_invalid_rate_prints_usage_instead_of_raising
    stdout = StringIO.new
    stderr = StringIO.new

    exit_code = Fixtures::Command.new(
      argv: ["missing-index", "drive", "--rate", "fast"],
      registry: {
        ["missing-index", "drive"] => ->(**) { flunk("handler should not run") },
      },
      manifest_loader: Class.new { define_singleton_method(:load) { |_| Struct.new(:seconds, :concurrency, :rate).new(60, 16, "unlimited") } },
      stdout: stdout,
      stderr: stderr,
    ).run

    assert_equal 1, exit_code
    assert_includes stderr.string, "Usage:"
  end

  def test_runtime_failure_keeps_runtime_error_message
    stdout = StringIO.new
    stderr = StringIO.new

    exit_code = Fixtures::Command.new(
      argv: ["missing-index", "drive"],
      registry: {
        ["missing-index", "drive"] => ->(**) { raise RuntimeError, "boom" },
      },
      manifest_loader: Class.new { define_singleton_method(:load) { |_| Struct.new(:seconds, :concurrency, :rate).new(60, 16, "unlimited") } },
      stdout: stdout,
      stderr: stderr,
    ).run

    assert_equal 1, exit_code
    refute_includes stderr.string, "Usage:"
    assert_includes stderr.string, "boom"
  end

  def test_all_without_a_registered_handler_fails_without_key_error
    stdout = StringIO.new
    stderr = StringIO.new

    exit_code = Fixtures::Command.new(
      argv: ["missing-index", "all"],
      registry: {
        ["missing-index", "reset"] => ->(**) {},
        ["missing-index", "drive"] => ->(**) {},
      },
      manifest_loader: Class.new { define_singleton_method(:load) { |_| Struct.new(:seconds, :concurrency, :rate).new(60, 16, "unlimited") } },
      stdout: stdout,
      stderr: stderr,
    ).run

    assert_equal 1, exit_code
    refute_includes stderr.string, "KeyError"
    assert_includes stderr.string, "Usage:"
  end
end
