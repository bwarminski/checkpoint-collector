# ABOUTME: Verifies workload scale defaults match the runner contract.
# ABOUTME: Locks the reserved-key behavior for scale extras.
require_relative "test_helper"

class ScaleTest < Minitest::Test
  def test_scale_defaults_extra_to_empty_hash
    scale = Load::Scale.new(rows_per_table: 10)

    assert_equal({}, scale.extra)
  end

  def test_env_pairs_upcases_extra_keys_and_always_emits_rows_per_table
    scale = Load::Scale.new(rows_per_table: 10, seed: 7, extra: { open_fraction: 0.6, batch_size: 25 })

    assert_equal(
      {
        "ROWS_PER_TABLE" => "10",
        "OPEN_FRACTION" => 0.6,
        "BATCH_SIZE" => 25,
      },
      scale.env_pairs,
    )
  end

  def test_env_pairs_excludes_seed
    scale = Load::Scale.new(rows_per_table: 10, seed: 99, extra: {})

    refute_includes scale.env_pairs.keys, "SEED"
  end

  def test_scale_rejects_extra_seed_key
    error = assert_raises(ArgumentError) do
      Load::Scale.new(rows_per_table: 10, extra: { seed: 99 })
    end

    assert_equal "extra cannot contain reserved key: seed", error.message
  end

  def test_scale_rejects_extra_rows_per_table_key
    error = assert_raises(ArgumentError) do
      Load::Scale.new(rows_per_table: 10, extra: { rows_per_table: 99 })
    end

    assert_equal "extra cannot contain reserved key: rows_per_table", error.message
  end
end
