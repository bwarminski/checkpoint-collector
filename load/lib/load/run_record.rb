# ABOUTME: Writes run metadata and append-only JSONL artifacts for a run.
# ABOUTME: Keeps the run directory layout simple for runner orchestration.
require "fileutils"
require "json"

module Load
  class RunRecord
    def initialize(run_dir:)
      @run_dir = run_dir
      FileUtils.mkdir_p(@run_dir)
    end

    attr_reader :run_dir

    def run_path
      File.join(@run_dir, "run.json")
    end

    def metrics_path
      File.join(@run_dir, "metrics.jsonl")
    end

    def adapter_commands_path
      File.join(@run_dir, "adapter-commands.jsonl")
    end

    def write_run(payload)
      temp_path = "#{run_path}.tmp"
      File.write(temp_path, JSON.pretty_generate(payload) + "\n")
      File.rename(temp_path, run_path)
    end

    def append_metrics(payload)
      append_jsonl(metrics_path, payload)
    end

    def append_adapter_command(payload)
      append_jsonl(adapter_commands_path, payload)
    end

    private

    def append_jsonl(path, payload)
      File.open(path, "a") do |file|
        file.puts(JSON.generate(payload))
      end
    end
  end
end
