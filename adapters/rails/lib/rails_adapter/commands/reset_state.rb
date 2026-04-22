# ABOUTME: Resets the benchmark database by rebuilding or cloning a template copy.
# ABOUTME: Reruns pg_stat_statements_reset after seeding so run counters start clean.
module RailsAdapter
  module Commands
    class ResetState
      def initialize(app_root:, seed:, env_pairs:, command_runner: RailsAdapter::CommandRunner.new, template_cache: RailsAdapter::TemplateCache.new, clock: -> { Time.now.to_f })
        @app_root = app_root
        @seed = seed
        @env_pairs = env_pairs
        @command_runner = command_runner
        @template_cache = template_cache
        @clock = clock
      end

      def call
        if @template_cache.template_exists?(database_name: database_name, app_root: @app_root, env_pairs: @env_pairs)
          @template_cache.clone_template(database_name: database_name, app_root: @app_root, env_pairs: @env_pairs)
        else
          build_template
          @template_cache.build_template(database_name: database_name, app_root: @app_root, env_pairs: @env_pairs)
        end

        reset_pg_stat_statements
        RailsAdapter::Result.ok("reset-state")
      rescue StandardError => error
        RailsAdapter::Result.error("reset-state", "reset_failed", error.message, {})
      end

      private

      def build_template
        migrate = @command_runner.capture3("bin/rails", "db:drop", "db:create", "db:migrate", env: rails_env, chdir: @app_root, command_name: "reset-state")
        raise "db:drop db:create db:migrate failed" unless migrate.success?

        seed = @command_runner.capture3(
          "bin/rails",
          "runner",
          %(load Rails.root.join("db/seeds.rb").to_s),
          env: rails_env.merge("SEED" => @seed.to_s).merge(@env_pairs),
          chdir: @app_root,
          command_name: "reset-state",
        )
        raise "seed runner failed" unless seed.success?
      end

      def reset_pg_stat_statements
        result = @command_runner.capture3(
          "bin/rails",
          "runner",
          %(ActiveRecord::Base.connection.execute("SELECT pg_stat_statements_reset()")),
          env: rails_env,
          chdir: @app_root,
          command_name: "reset-state",
        )
        raise "pg_stat_statements_reset failed" unless result.success?
      end

      def database_name
        ENV.fetch("BENCHMARK_DB_NAME", "checkpoint_demo")
      end

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
