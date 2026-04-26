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
        args: redact_args(argv.drop(1)),
        exit_code: status.exitstatus,
        duration_ms: ((ended_at - started_at) * 1000).round,
        stdout_json:,
        stderr: redact_text(stderr.to_s),
      )
      raise AdapterError, adapter_error_message(stdout_json, stderr) unless status.success?

      stdout_json
    rescue JSON::ParserError => error
      append_adapter_command(
        ts: started_at,
        command: argv.first,
        args: redact_args(argv.drop(1)),
        exit_code: status&.exitstatus,
        duration_ms: started_at && ended_at ? ((ended_at - started_at) * 1000).round : nil,
        stdout_json: nil,
        stderr: redact_text(stderr.to_s),
      )
      raise AdapterError, error.message
    end

    def append_adapter_command(payload)
      @run_record&.append_adapter_command(payload)
    end

    def redact_args(args)
      args.each_slice(2).flat_map do |flag, value|
        if flag == "--env" && value
          [flag, redact_env_pair(value)]
        else
          [flag, value].compact
        end
      end
    end

    def redact_env_pair(value)
      key, env_value = value.split("=", 2)
      return value unless env_value
      return "#{key}=[REDACTED]" if sensitive_key?(key)

      "#{key}=#{redact_text(env_value)}"
    end

    def redact_text(text)
      redacted = text.gsub(%r{(://[^:\s]+:)[^@\s]+@}, '\1[REDACTED]@')
      redacted.gsub(/((?:\A|[\s,])(?:[A-Z0-9_]*?(?:URL|PASSWORD|TOKEN|KEY|SECRET)))=([^\s,]+)/, '\1=[REDACTED]')
    end

    def adapter_error_message(stdout_json, stderr)
      parts = [stderr.to_s.strip]
      error = stdout_json.fetch("error", {})
      details = error.fetch("details", {})
      parts << error.fetch("message", nil)
      parts << details.fetch("stderr", nil)
      redact_text(parts.compact.map(&:to_s).map(&:strip).reject(&:empty?).join("\n"))
    end

    def sensitive_key?(key)
      key.match?(/(?:URL|PASSWORD|TOKEN|KEY|SECRET)\z/)
    end
  end
end
