# ABOUTME: Stops a benchmark Rails server process by pid using signal polling.
# ABOUTME: Avoids waitpid because start and stop run in separate adapter processes.
module RailsAdapter
  module Commands
    class Stop
      def initialize(pid:, process_killer: Process, clock: -> { Time.now.to_f }, sleeper: ->(seconds) { sleep(seconds) })
        @pid = pid
        @process_killer = process_killer
        @clock = clock
        @sleeper = sleeper
      end

      def call
        @process_killer.kill("TERM", process_group_pid)
        return RailsAdapter::Result.ok("stop") unless alive_within?(10.0)

        @process_killer.kill("KILL", process_group_pid)
        return RailsAdapter::Result.ok("stop") unless alive_within?(2.0)

        RailsAdapter::Result.error("stop", "stop_failed", "process did not exit", {})
      rescue Errno::ESRCH
        RailsAdapter::Result.ok("stop")
      end

      private

      def alive_within?(budget_seconds)
        deadline = @clock.call + budget_seconds
        loop do
          @process_killer.kill(0, process_group_pid)
          return true if @clock.call >= deadline

          @sleeper.call(0.2)
        rescue Errno::ESRCH
          return false
        end
      end

      def process_group_pid
        -@pid
      end
    end
  end
end
