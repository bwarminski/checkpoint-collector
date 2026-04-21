# ABOUTME: Invokes the adapter binary for load runner lifecycle commands.
# ABOUTME: Captures JSON output from the adapter and forwards scale env values.
require "json"
require "open3"

module Load
  class AdapterClient
    AdapterError = Class.new(StandardError)

    def initialize(adapter_bin:, capture3: nil)
      @adapter_bin = adapter_bin
      @capture3 = capture3 || ->(*argv) { Open3.capture3(*argv) }
    end

    attr_reader :adapter_bin

    def describe
      invoke("describe")
    end

    def prepare(app_root:)
      invoke("prepare", "--app-root", app_root)
    end

    def reset_state(app_root:, scale:)
      invoke(
        "reset-state",
        "--app-root", app_root,
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
      stdout, stderr, status = @capture3.call(@adapter_bin, *argv)
      raise AdapterError, stderr unless status.success?

      stdout.to_s.empty? ? {} : JSON.parse(stdout)
    rescue JSON::ParserError => error
      raise AdapterError, error.message
    end
  end
end
