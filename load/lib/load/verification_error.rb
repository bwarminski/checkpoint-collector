# ABOUTME: Defines the shared failure type for workload-owned verification checks.
# ABOUTME: Lets core load code rescue verification failures without fixture-specific knowledge.
module Load
  VerificationError = Class.new(StandardError)
end
