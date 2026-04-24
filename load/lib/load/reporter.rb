# ABOUTME: Merges worker buffers into interval snapshots for later writing.
# ABOUTME: Provides an explicit snapshot_once hook and a final flush on stop.
module Load
  class Reporter
    class Shutdown < StandardError; end

    def initialize(workers:, interval_seconds:, sink:, clock:, sleeper:)
      @workers = workers
      @interval_seconds = interval_seconds
      @sink = sink
      @clock = clock
      @sleeper = sleeper
      @thread = nil
      @running = false
      @mutex = Mutex.new
      @state_mutex = Mutex.new
      @sleeping = false
      @last_snapshot_ts = nil
    end

    def start
      return self if @thread&.alive?

      @running = true
      @thread = Thread.new do
        begin
          loop do
            break unless @running
            begin
              Thread.handle_interrupt(Shutdown => :immediate) do
                mark_sleeping(true)
                @sleeper.call(@interval_seconds)
              end
            rescue StopIteration, Shutdown
              break
            ensure
              mark_sleeping(false)
            end
            break unless @running
            Thread.handle_interrupt(Shutdown => :never) do
              snapshot_once
            end
          end
        rescue Exception => error
          raise unless error == Shutdown || error.is_a?(Shutdown)
        end
      end

      self
    end

    def stop
      @running = false
      if @thread && @thread != Thread.current
        @thread.raise(Shutdown.new) if sleeping? && @thread.alive?
        @thread.join
      end
      snapshot_once
      self
    end

    def snapshot_once
      @mutex.synchronize do
        merged = {}

        @workers.each do |worker|
          worker.buffer.swap!.each do |action, bucket|
            merged[action] ||= fresh_bucket
            merged[action][:latencies_ns].concat(bucket.fetch(:latencies_ns, []))
            merged[action][:status_counts].merge!(bucket.fetch(:status_counts, {})) { |_key, left, right| left + right }
            merged[action][:errors_by_class].merge!(bucket.fetch(:errors_by_class, {})) { |_key, left, right| left + right }
          end
        end

        now = @clock.call
        line = {
          ts: now,
          interval_ms: snapshot_interval_ms(now),
          actions: Load::Metrics::Snapshot.build(merged),
        }
        @last_snapshot_ts = now
        @sink << line
        line
      end
    end

    private

    def snapshot_interval_ms(now)
      return (@interval_seconds * 1000).to_i unless @last_snapshot_ts

      ((now - @last_snapshot_ts) * 1000).round
    end

    def mark_sleeping(value)
      @state_mutex.synchronize do
        @sleeping = value
      end
    end

    def sleeping?
      @state_mutex.synchronize do
        @sleeping
      end
    end

    def fresh_bucket
      {
        latencies_ns: [],
        status_counts: Hash.new(0),
        errors_by_class: Hash.new(0),
      }
    end
  end
end
