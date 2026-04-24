# ABOUTME: Verifies workload scale defaults match the runner contract.
# ABOUTME: Ensures optional scale fields can be omitted.
require_relative "test_helper"

class ScaleTest < Minitest::Test
  def test_open_fraction_defaults_to_nil
    scale = Load::Scale.new(rows_per_table: 10)

    assert_nil scale.open_fraction
  end
end
