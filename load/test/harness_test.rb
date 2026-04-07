# ABOUTME: Verifies the demo load harness exposes the expected request paths.
# ABOUTME: Keeps the harness aligned with the endpoints used by the demo app.
require "minitest/autorun"
require_relative "../harness"

class HarnessTest < Minitest::Test
  def test_requests_all_demo_endpoints
    urls = Harness.new(base_url: "http://demo:3000").request_paths

    assert_includes urls, "/todos"
    assert_includes urls, "/todos?q=task"
    assert_includes urls, "/todos/status"
    assert_includes urls, "/todos/stats"
  end
end
