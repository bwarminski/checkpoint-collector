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
end
