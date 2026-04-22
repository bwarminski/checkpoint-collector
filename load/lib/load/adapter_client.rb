# ABOUTME: Invokes the adapter binary for load runner lifecycle commands.
# ABOUTME: Captures JSON output from the adapter and forwards scale env values.
require "json"
require "open3"

module Load
  class AdapterClient
    AdapterError = Class.new(StandardError)

    def initialize(adapter_bin:, capture3: nil, run_record: nil, clock: -> { Time.now.utc })
      @adapter_bin = adapter_bin
      @capture3 = capture3 || ->(*argv) { Open3.capture3(*argv) }
      @run_record = run_record
      @clock = clock
    end

    attr_reader :adapter_bin

    def describe
      invoke("describe")
    end

    def prepare(app_root:)
      invoke("prepare", "--app-root", app_root)
    end

    def reset_state(app_root:, workload:, scale:)
      invoke(
        "reset-state",
        "--app-root", app_root,
        "--workload", workload,
        "--seed", scale.seed.to_s,
        *scale.env_pairs.flat_map { |key, value| ["--env", "#{key}=#{value}"] },
      )
    end

    def start(app_root:)
      invoke("start", "--app-root", app_root)
    end

    def stop(pid:)
      invoke("stop", "--pid", pid.to_s)
    end

    private

    def invoke(*argv)
      started_at = @clock.call
      full_argv = ["--json", *argv]
      stdout, stderr, status = @capture3.call(@adapter_bin, *full_argv)
      ended_at = @clock.call
      stdout_json = stdout.to_s.empty? ? {} : JSON.parse(stdout)
      append_adapter_command(
        ts: started_at,
        command: argv.first,
        args: full_argv,
        exit_code: status.exitstatus,
        duration_ms: ((ended_at - started_at) * 1000).round,
        stdout_json:,
        stderr: stderr.to_s,
      )
      raise AdapterError, stderr unless status.success?

      stdout_json
    rescue JSON::ParserError => error
      append_adapter_command(
        ts: started_at,
        command: argv.first,
        args: ["--json", *argv],
        exit_code: status&.exitstatus,
        duration_ms: started_at && ended_at ? ((ended_at - started_at) * 1000).round : nil,
        stdout_json: nil,
        stderr: stderr.to_s,
      )
      raise AdapterError, error.message
    end

    def append_adapter_command(payload)
      @run_record&.append_adapter_command(payload)
    end
  end
end
