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

  def test_reset_does_not_eagerly_require_drive_or_assert_files
    stdout = StringIO.new
    stderr = StringIO.new
    events = []

    with_require_guard(events) do
      exit_code = Fixtures::Command.new(
        argv: ["missing-index", "reset"],
        manifest_loader: Class.new { define_singleton_method(:load) { |_| Struct.new(:seconds, :concurrency, :rate).new(60, 16, "unlimited") } },
        stdout: stdout,
        stderr: stderr,
      ).run

      assert_equal 0, exit_code
    end

    assert_equal [:reset_require], events
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

  private

  def with_require_guard(events)
    original_require = Kernel.instance_method(:require)
    fixture_module_created = false
    fixture_module = if Fixtures.const_defined?(:MissingIndex, false)
      Fixtures.const_get(:MissingIndex, false)
    else
      fixture_module_created = true
      Fixtures.const_set(:MissingIndex, Module.new)
    end

    Kernel.module_eval do
      define_method(:require) do |path|
        case path
        when %r{/fixtures/missing-index/setup/reset$}
          events << :reset_require
          fixture_module.const_set(:Reset, Class.new do
            def initialize(**); end

            def run
              0
            end
          end)
          true
        when %r{/fixtures/missing-index/load/drive$}, %r{/fixtures/missing-index/validate/assert$}
          raise "unexpected require: #{path}"
        else
          original_require.bind(self).call(path)
        end
      end
    end

    yield
  ensure
    Kernel.module_eval do
      remove_method :require
      define_method(:require, original_require)
    end

    fixture_module.send(:remove_const, :Reset) if fixture_module.const_defined?(:Reset, false)
    Fixtures.send(:remove_const, :MissingIndex) if fixture_module_created
  end
end
