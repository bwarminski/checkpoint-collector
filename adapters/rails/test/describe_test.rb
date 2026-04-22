# ABOUTME: Verifies the describe command returns adapter metadata and error shape.
# ABOUTME: Covers the adapter JSON contract for a simple command.
require_relative "test_helper"

class DescribeTest < Minitest::Test
  def test_error_response_shape_matches_contract
    command = RailsAdapter::Commands::Describe.new(force_failure: StandardError.new("synthetic"))

    result = command.call

    refute result.fetch("ok")
    assert_equal "describe", result.fetch("command")
    assert_kind_of String, result.dig("error", "code")
    assert_kind_of String, result.dig("error", "message")
    assert_kind_of Hash, result.dig("error", "details")
  end
end
