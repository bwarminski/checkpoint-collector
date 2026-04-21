# ABOUTME: Collects per-action request latencies and outcome counts in memory.
# ABOUTME: Builds interval snapshots for reporter output and run records.
module Load
  module Metrics
    class Buffer
      def initialize
        @mutex = Mutex.new
        @data = fresh_data
      end

      def record_ok(action:, latency_ns:, status:)
        @mutex.synchronize do
          bucket = (@data[action] ||= fresh_bucket)
          bucket[:latencies_ns] << latency_ns
          bucket[:status_counts][status.to_s] += 1
        end
      end

      def record_error(action:, latency_ns:, error_class:)
        @mutex.synchronize do
          bucket = (@data[action] ||= fresh_bucket)
          bucket[:latencies_ns] << latency_ns
          bucket[:errors_by_class][error_class] += 1
        end
      end

      def swap!
        @mutex.synchronize do
          current = @data
          @data = fresh_data
          current
        end
      end

      private

      def fresh_data
        {}
      end

      def fresh_bucket
        {
          latencies_ns: [],
          status_counts: Hash.new(0),
          errors_by_class: Hash.new(0),
        }
      end
    end

    class Snapshot
      def self.build(snapshot)
        snapshot.each_with_object({}) do |(action, bucket), stats|
          latencies_ns = bucket.fetch(:latencies_ns, [])
          stats[action] = {
            count: latencies_ns.length,
            error_count: bucket.fetch(:errors_by_class, {}).values.sum,
            p95_ms: percentile_ms(latencies_ns, 0.95),
            status_counts: bucket.fetch(:status_counts, {}).dup,
            errors_by_class: bucket.fetch(:errors_by_class, {}).dup,
          }
        end
      end

      def self.percentile_ms(latencies_ns, percentile)
        return 0.0 if latencies_ns.empty?

        sorted = latencies_ns.sort
        index = (percentile * (sorted.length - 1)).floor
        sorted.fetch(index).fdiv(1_000_000)
      end
      private_class_method :percentile_ms
    end
  end
end
