# ABOUTME: Spawns the benchmark Rails server on a selected localhost port.
# ABOUTME: Returns pid and base_url without detaching the child process.
module RailsAdapter
  module Commands
    class Start
      def initialize(app_root:, port_finder: RailsAdapter::PortFinder.new, spawner: RailsAdapter::ProcessSpawner.new)
        @app_root = app_root
        @port_finder = port_finder
        @spawner = spawner
      end

      def call
        port = @port_finder.next_available_port
        return RailsAdapter::Result.error("start", "port_exhausted", "no free port in 3000..3020", {}) unless port

        pid = @spawner.spawn(
          "bin/rails",
          "server",
          "-p",
          port.to_s,
          "-b",
          "127.0.0.1",
          chdir: @app_root,
          env: rails_env,
          in: "/dev/null",
          out: "/tmp/bench-adapter-#{Process.pid}-start.log",
          pgroup: true,
        )

        RailsAdapter::Result.ok("start", "pid" => pid, "base_url" => "http://127.0.0.1:#{port}")
      rescue StandardError => error
        RailsAdapter::Result.error("start", "start_failed", error.message, {})
      end

      private

      def rails_env
        RailsAdapter::Environment.benchmark(@app_root)
      end
    end
  end
end
