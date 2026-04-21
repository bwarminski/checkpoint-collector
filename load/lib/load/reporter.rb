# ABOUTME: Merges worker buffers into interval snapshots for later writing.
# ABOUTME: Provides an explicit snapshot_once hook and a final flush on stop.
module Load
  class Reporter
    def initialize(workers:, interval_seconds:, sink:, clock:, sleeper:)
      @workers = workers
      @interval_seconds = interval_seconds
      @sink = sink
      @clock = clock
      @sleeper = sleeper
      @started = false
    end

    def start
      @started = true
      self
    end

    def stop
      snapshot_once if @started
      @started = false
    end

    def snapshot_once
      merged = {}

      @workers.each do |worker|
        worker.buffer.swap!.each do |action, bucket|
          merged[action] ||= fresh_bucket
          merged[action][:latencies_ns].concat(bucket.fetch(:latencies_ns, []))
          merged[action][:status_counts].merge!(bucket.fetch(:status_counts, {})) { |_key, left, right| left + right }
          merged[action][:errors_by_class].merge!(bucket.fetch(:errors_by_class, {})) { |_key, left, right| left + right }
        end
      end

      line = {
        timestamp: @clock.call,
        actions: Load::Metrics::Snapshot.build(merged),
      }
      @sink << line
      line
    end

    private

    def fresh_bucket
      {
        latencies_ns: [],
        status_counts: Hash.new(0),
        errors_by_class: Hash.new(0),
      }
    end
  end
end
