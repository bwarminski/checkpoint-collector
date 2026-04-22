# ABOUTME: Checks bundle dependencies and benchmark DB reachability for the app.
# ABOUTME: Fails fast when the Rails app is not ready for benchmark commands.
module RailsAdapter
  module Commands
    class Prepare
      def initialize(app_root:, command_runner: RailsAdapter::CommandRunner.new)
        @app_root = app_root
        @command_runner = command_runner
      end

      def call
        result = @command_runner.capture3("bundle", "check", env: {}, chdir: @app_root, command_name: "prepare")
        return RailsAdapter::Result.error("prepare", "bundle_missing", "bundle check failed", { "stderr" => result.stderr }) unless result.success?

        ping = @command_runner.capture3(
          "bin/rails",
          "runner",
          %(ActiveRecord::Base.connection.execute("SELECT 1")),
          env: rails_env,
          chdir: @app_root,
          command_name: "prepare",
        )
        return RailsAdapter::Result.error("prepare", "db_unreachable", "benchmark database is unreachable", { "stderr" => ping.stderr }) unless ping.success?

        RailsAdapter::Result.ok("prepare")
      end

      private

      def rails_env
        {
          "BUNDLE_GEMFILE" => File.join(@app_root, "Gemfile"),
          "RAILS_ENV" => "benchmark",
          "RAILS_LOG_LEVEL" => "warn",
        }
      end
    end
  end
end
