# ABOUTME: Runs Rails subprocess commands with the benchmark adapter environment.
# ABOUTME: Wraps Open3 so commands can be tested with injected fakes.
require "open3"

module RailsAdapter
  class CommandRunner
    Result = Struct.new(:status, :stdout, :stderr, keyword_init: true) do
      def success?
        status.to_i.zero?
      end
    end

    def capture3(*argv, env:, chdir:, command_name:)
      merged_env = ENV.to_h.merge(env)
      stdout, stderr, status = Open3.capture3(merged_env, *argv, chdir:)
      Result.new(status: status.exitstatus, stdout:, stderr:)
    end
  end
end
