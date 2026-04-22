# ABOUTME: Runs Rails database creation and migrations for the benchmark app.
# ABOUTME: Returns the resulting schema version in the adapter JSON contract.
module RailsAdapter
  module Commands
    class Migrate
      def initialize(app_root:, command_runner: RailsAdapter::CommandRunner.new)
        @app_root = app_root
        @command_runner = command_runner
      end

      def call
        run = @command_runner.capture3("bin/rails", "db:create", "db:schema:load", env: rails_env, chdir: @app_root, command_name: "migrate")
        return RailsAdapter::Result.error("migrate", "migrate_failed", "db:create db:schema:load failed", { "stderr" => run.stderr }) unless run.success?

        version = @command_runner.capture3(
          "bin/rails",
          "runner",
          "puts ActiveRecord::Base.connection.migration_context.current_version",
          env: rails_env,
          chdir: @app_root,
          command_name: "migrate",
        )
        return RailsAdapter::Result.error("migrate", "schema_version_failed", "could not read schema version", { "stderr" => version.stderr }) unless version.success?

        RailsAdapter::Result.ok("migrate", "schema_version" => version.stdout.to_s.strip)
      end

      private

      def rails_env
        RailsAdapter::Environment.benchmark(@app_root)
      end
    end
  end
end
