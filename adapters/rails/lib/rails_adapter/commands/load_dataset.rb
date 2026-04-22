# ABOUTME: Loads workload seed data into the benchmark Rails app.
# ABOUTME: Propagates scale env vars into the Rails seeds runner command.
module RailsAdapter
  module Commands
    class LoadDataset
      def initialize(app_root:, workload:, seed:, env_pairs:, command_runner: RailsAdapter::CommandRunner.new, clock: -> { Time.now.to_f })
        @app_root = app_root
        @workload = workload
        @seed = seed
        @env_pairs = env_pairs
        @command_runner = command_runner
        @clock = clock
      end

      def call
        started_at = @clock.call
        result = @command_runner.capture3(
          "bin/rails",
          "runner",
          %(load Rails.root.join("db/seeds.rb").to_s),
          env: rails_env.merge("SEED" => @seed.to_s).merge(@env_pairs),
          chdir: @app_root,
          command_name: "load-dataset",
        )
        return RailsAdapter::Result.error("load-dataset", "seed_failed", "seed runner failed", { "stderr" => result.stderr }) unless result.success?

        RailsAdapter::Result.ok(
          "load-dataset",
          "loaded_rows" => @env_pairs.fetch("ROWS_PER_TABLE", nil),
          "duration_ms" => elapsed_ms(started_at),
        )
      end

      private

      def elapsed_ms(started_at)
        ((@clock.call - started_at) * 1000).round
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
