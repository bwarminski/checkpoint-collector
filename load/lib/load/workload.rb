# ABOUTME: Declares the base class for a runnable workload.
# ABOUTME: Concrete workloads provide the name, scale, actions, and plan.
module Load
  class Workload
    def name
      raise NotImplementedError
    end

    def scale
      raise NotImplementedError
    end

    def actions
      raise NotImplementedError
    end

    def load_plan
      raise NotImplementedError
    end

    def invariant_sampler(database_url:, pg:)
      nil
    end
  end
end
