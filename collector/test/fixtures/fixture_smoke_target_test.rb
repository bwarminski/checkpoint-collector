# ABOUTME: Verifies the manual fixture-smoke make target points at the fixture harness.
# ABOUTME: Checks the target command before the Makefile exists or changes.
require "minitest/autorun"

class FixtureSmokeTargetTest < Minitest::Test
  def test_makefile_defines_fixture_smoke_target
    makefile = File.read(File.expand_path("../../../Makefile", __dir__))

    assert_match(/^fixture-smoke:/, makefile)
    assert_includes makefile, "bin/fixture missing-index all"
  end
end
