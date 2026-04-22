# ABOUTME: Runs Rails subprocess commands with the benchmark adapter environment.
# ABOUTME: Wraps Open3 so commands can be tested with injected fakes.
require "bundler"
require "open3"

module RailsAdapter
  class CommandRunner
    Result = Struct.new(:status, :stdout, :stderr, keyword_init: true) do
      def success?
        status.to_i.zero?
      end
    end

    def capture3(*argv, env:, chdir:, command_name:)
      merged_env = Bundler.unbundled_env.merge(preserved_bundle_env).merge(env)
      stdout, stderr, status = Bundler.with_unbundled_env do
        Open3.capture3(merged_env, *argv, chdir:)
      end
      Result.new(status: status.exitstatus, stdout:, stderr:)
    end

    private

    def preserved_bundle_env
      ENV.to_h.slice("BUNDLE_PATH", "BUNDLE_USER_HOME", "GEM_HOME", "GEM_PATH")
    end
  end
end
