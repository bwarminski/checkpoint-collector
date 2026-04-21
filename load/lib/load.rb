# ABOUTME: Defines the top-level namespace for the load runner.
# ABOUTME: Loads the load runner foundation classes and value objects.
require_relative "load/action"
require_relative "load/action_entry"
require_relative "load/load_plan"
require_relative "load/rate_limiter"
require_relative "load/scale"
require_relative "load/selector"
require_relative "load/workload"

module Load
end
