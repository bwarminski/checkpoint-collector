# ABOUTME: Resets the benchmark database by rebuilding or cloning a template copy.
# ABOUTME: Reruns pg_stat_statements_reset after seeding so run counters start clean.
require "json"
require "uri"

module RailsAdapter
  module Commands
    class ResetState
      QUERY_IDS_SCRIPT = {
        "missing-index-todos" => <<~RUBY.strip,
          require "json"
          Todo.where(status: "open").load
          connection = ActiveRecord::Base.connection
          query_ids = [
            %(SELECT "todos".* FROM "todos" WHERE "todos"."status" = $1),
            %(SELECT "todos".* FROM "todos" WHERE "todos"."status" = 'open'),
          ].flat_map do |query_text|
            connection.exec_query(
              "SELECT DISTINCT queryid::text AS queryid FROM pg_stat_statements WHERE query = \#{connection.quote(query_text)}"
            ).rows.flatten
          end.uniq
          $stdout.write(JSON.generate(query_ids: query_ids))
        RUBY
      }.freeze

      def initialize(app_root:, seed:, env_pairs:, workload: nil, command_runner: RailsAdapter::CommandRunner.new, template_cache: RailsAdapter::TemplateCache.new, clock: -> { Time.now.to_f })
        @app_root = app_root
        @workload = workload
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

        ensure_pg_stat_statements
        query_ids = capture_query_ids
        reset_pg_stat_statements
        RailsAdapter::Result.ok("reset-state", query_ids ? { "query_ids" => query_ids } : {})
      rescue StandardError => error
        RailsAdapter::Result.error("reset-state", "reset_failed", error.message, {})
      end

      private

      def build_template
        migrate = @command_runner.capture3("bin/rails", "db:drop", "db:create", "db:schema:load", env: rails_env, chdir: @app_root, command_name: "reset-state")
        raise "db:drop db:create db:schema:load failed" unless migrate.success?

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

      def ensure_pg_stat_statements
        result = @command_runner.capture3(
          "bin/rails",
          "runner",
          %(ActiveRecord::Base.connection.execute("CREATE EXTENSION IF NOT EXISTS pg_stat_statements")),
          env: rails_env,
          chdir: @app_root,
          command_name: "reset-state",
        )
        raise "pg_stat_statements extension failed" unless result.success?
      end

      def capture_query_ids
        script = QUERY_IDS_SCRIPT[@workload]
        return nil unless script

        result = @command_runner.capture3(
          "bin/rails",
          "runner",
          script,
          env: rails_env,
          chdir: @app_root,
          command_name: "reset-state",
        )
        raise "query id capture failed" unless result.success?

        JSON.parse(result.stdout).fetch("query_ids")
      end

      def database_name
        return ENV.fetch("BENCHMARK_DB_NAME") if ENV.key?("BENCHMARK_DB_NAME")

        database_url = ENV["DATABASE_URL"]
        return "checkpoint_demo" unless database_url

        path = URI.parse(database_url).path
        name = path.sub(%r{\A/}, "")
        name.empty? ? "checkpoint_demo" : name
      end

      def rails_env
        RailsAdapter::Environment.benchmark(@app_root)
      end
    end
  end
end
