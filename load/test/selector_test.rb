# ABOUTME: Verifies seeded selection repeats the same weighted sequence.
# ABOUTME: Confirms the selector uses the provided random source.
require_relative "test_helper"

AlphaAction = Class.new
BetaAction = Class.new

class SelectorTest < Minitest::Test
  def test_seeded_selector_is_repeatable
    entries = [
      Load::ActionEntry.new(AlphaAction, 1),
      Load::ActionEntry.new(BetaAction, 3),
    ]

    selector_a = Load::Selector.new(entries:, rng: Random.new(42))
    selector_b = Load::Selector.new(entries:, rng: Random.new(42))

    assert_equal 20.times.map { selector_a.next.action_class }, 20.times.map { selector_b.next.action_class }
  end
end
