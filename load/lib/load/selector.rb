# ABOUTME: Selects actions from a weighted list using a seeded random source.
# ABOUTME: Precomputes cumulative weights for repeatable picks.
module Load
  class Selector
    def initialize(entries:, rng:)
      @entries = entries
      @rng = rng
      @thresholds = []
      total_weight = 0

      entries.each do |entry|
        total_weight += entry.weight
        @thresholds << total_weight
      end

      @total_weight = total_weight
    end

    def next
      ticket = @rng.rand * @total_weight
      index = @thresholds.bsearch_index { |threshold| threshold > ticket }
      @entries.fetch(index)
    end
  end
end
