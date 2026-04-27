# ABOUTME: Resets the benchmark database by rebuilding or cloning a template copy.
# ABOUTME: Reruns pg_stat_statements_reset after seeding so run counters start clean.
require "json"
require "uri"

module RailsAdapter
  module Commands
    class ResetState
      def initialize(app_root:, seed:, env_pairs:, workload: nil, command_runner: RailsAdapter::CommandRunner.new, template_cache: RailsAdapter::TemplateCache.new, reset_strategy: ENV.fetch("BENCH_ADAPTER_RESET_STRATEGY", "local"), workload_root: File.join(RailsAdapter::REPO_ROOT, "workloads"), clock: -> { Time.now.to_f })
        @app_root = app_root
        @workload = workload
        @seed = seed
        @env_pairs = env_pairs
        @command_runner = command_runner
        @template_cache = template_cache
        @reset_strategy = reset_strategy
        @workload_root = workload_root
        @clock = clock
      end

      def call
        case @reset_strategy
        when "local"
          reset_local
        when "remote"
          reset_remote
        else
          raise ArgumentError, "unknown reset strategy: #{@reset_strategy}"
        end

        ensure_pg_stat_statements
        query_ids = capture_query_ids
        reset_pg_stat_statements
        RailsAdapter::Result.ok("reset-state", query_ids ? { "query_ids" => query_ids } : {})
      rescue StandardError => error
        RailsAdapter::Result.error("reset-state", "reset_failed", error.message, {})
      end

      private

      def reset_local
        if @template_cache.template_exists?(database_name: database_name, app_root: @app_root, env_pairs: seed_env)
          @template_cache.clone_template(database_name: database_name, app_root: @app_root, env_pairs: seed_env)
        else
          build_template
          @template_cache.build_template(database_name: database_name, app_root: @app_root, env_pairs: seed_env)
        end
      end

      def reset_remote
        schema = @command_runner.capture3(
          "bin/rails",
          "db:schema:load",
          env: rails_env,
          chdir: @app_root,
          command_name: "reset-state",
        )
        raise command_failure_message("schema load failed", schema.stderr) unless schema.success?

        load_dataset = RailsAdapter::Commands::LoadDataset.new(
          app_root: @app_root,
          workload: @workload,
          seed: @seed,
          env_pairs: @env_pairs,
          command_runner: @command_runner,
          clock: @clock,
        ).call
        raise result_failure_message("seed failed", load_dataset) unless load_dataset.fetch("ok")
      end

      def build_template
        drop = @command_runner.capture3("bin/rails", "db:drop", env: rails_env, chdir: @app_root, command_name: "reset-state")
        raise command_failure_message("db:drop failed", drop.stderr) unless drop.success?

        migrate = RailsAdapter::Commands::Migrate.new(app_root: @app_root, command_runner: @command_runner).call
        raise result_failure_message("db:create db:schema:load failed", migrate) unless migrate.fetch("ok")

        load_dataset = RailsAdapter::Commands::LoadDataset.new(
          app_root: @app_root,
          workload: @workload,
          seed: @seed,
          env_pairs: @env_pairs,
          command_runner: @command_runner,
          clock: @clock,
        ).call
        raise result_failure_message("seed runner failed", load_dataset) unless load_dataset.fetch("ok")
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
        raise command_failure_message("pg_stat_statements_reset failed", result.stderr) unless result.success?
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
        raise command_failure_message("pg_stat_statements extension failed", result.stderr) unless result.success?
      end

      def capture_query_ids
        path = query_ids_script_path
        return nil unless path

        result = @command_runner.capture3(
          "bin/rails",
          "runner",
          path,
          env: rails_env,
          chdir: @app_root,
          command_name: "reset-state",
        )
        raise command_failure_message("query id capture failed", result.stderr) unless result.success?

        query_ids = JSON.parse(result.stdout).fetch("query_ids")
        raise TypeError, "query_ids must be an array" unless query_ids.is_a?(Array)

        query_ids
      end

      def query_ids_script_path
        return nil unless @workload

        path = File.join(@workload_root, @workload.tr("-", "_"), "rails", "reset_state_query_ids.rb")
        File.exist?(path) ? path : nil
      end

      def command_failure_message(message, detail)
        detail = detail.to_s.strip
        detail.empty? ? message : "#{message}: #{detail}"
      end

      def result_failure_message(message, result)
        error = result.fetch("error")
        details = error.fetch("details", {})
        [
          message,
          error.fetch("message", nil),
          details.fetch("stderr", nil),
        ].compact.map(&:to_s).map(&:strip).reject(&:empty?).join(": ")
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

      def seed_env
        @seed_env ||= @env_pairs.merge("SEED" => @seed.to_s)
      end
    end
  end
end
