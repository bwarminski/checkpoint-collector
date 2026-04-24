# ABOUTME: Verifies the bench-adapter binary preserves the JSON error contract.
# ABOUTME: Covers command-dispatch failures that happen before any adapter command runs.
require "json"
require "open3"
require "rbconfig"
require_relative "test_helper"

class BinAdapterTest < Minitest::Test
  def test_unknown_command_returns_json_error
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, bench_adapter_path, "--json", "bogus")

    refute status.success?
    assert_equal "", stderr

    payload = JSON.parse(stdout)
    refute payload.fetch("ok")
    assert_equal "bogus", payload.fetch("command")
    assert_equal "unknown_command", payload.dig("error", "code")
  end

  private

  def bench_adapter_path
    @bench_adapter_path ||= File.expand_path("../bin/bench-adapter", __dir__)
  end
end
