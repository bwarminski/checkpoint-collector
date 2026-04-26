# ABOUTME: Describes the scale parameters for a workload.
# ABOUTME: Exposes environment variable pairs for workload extras.
module Load
  Scale = Data.define(:rows_per_table, :seed, :extra) do
    def initialize(rows_per_table:, seed: 42, extra: {})
      reserved = %w[seed rows_per_table]
      bad = extra.keys.find { |key| reserved.include?(key.to_s.downcase) }
      raise ArgumentError, "extra cannot contain reserved key: #{bad}" if bad
      normalized = extra.keys.group_by { |key| key.to_s.upcase }
      duplicate = normalized.find { |_, keys| keys.length > 1 }&.first
      raise ArgumentError, "extra cannot contain duplicate key after normalization: #{duplicate}" if duplicate

      super(rows_per_table:, seed:, extra: extra.transform_keys(&:to_sym))
    end

    def env_pairs
      { "ROWS_PER_TABLE" => rows_per_table.to_s }
        .merge(extra.transform_keys { |key| key.to_s.upcase })
    end
  end
end
