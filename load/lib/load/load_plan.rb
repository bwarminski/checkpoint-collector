# ABOUTME: Describes how a workload should be executed.
# ABOUTME: Stores worker count, runtime, rate limit, and seed.
module Load
  LoadPlan = Data.define(:workers, :duration_seconds, :rate_limit, :seed) do
    def initialize(workers:, duration_seconds:, rate_limit: :unlimited, seed: nil)
      super
    end
  end
end
