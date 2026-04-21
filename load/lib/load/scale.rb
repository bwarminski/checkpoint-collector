# ABOUTME: Describes the scale parameters for a workload.
# ABOUTME: Exposes environment variable pairs for non-nil scale fields.
module Load
  Scale = Data.define(:rows_per_table, :open_fraction, :seed) do
    def initialize(rows_per_table:, open_fraction: nil, seed: 42)
      super
    end

    def env_pairs
      to_h.each_with_object({}) do |(key, value), pairs|
        next if key == :seed || value.nil?

        pairs[key.to_s.upcase] = value
      end
    end
  end
end
