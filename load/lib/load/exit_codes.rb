# ABOUTME: Names the process exit codes returned by the load runner CLI.
# ABOUTME: Keeps command and runner outcomes readable at call sites.
module Load
  module ExitCodes
    SUCCESS = 0
    ADAPTER_ERROR = 1
    USAGE_ERROR = 2
    NO_SUCCESSFUL_REQUESTS = 3
  end
end
