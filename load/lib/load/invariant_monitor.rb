# ABOUTME: Runs the invariant sampler thread and applies breach policy.
# ABOUTME: Emits samples, warnings, and stop signals without owning run-record schema.
require "thread"

module Load
  class InvariantMonitor
    Failure = Class.new(StandardError)
    Shutdown = Class.new(StandardError)

    Config = Data.define(:policy, :interval_seconds) do
      def off?
        policy == :off
      end

      def warn?
        policy == :warn
      end

      def enforce?
        policy == :enforce
      end
    end

    Sink = Data.define(:on_sample, :on_warning, :on_breach_stop, :stderr) do
      def sample(sample)
        on_sample.call(sample)
      end

      def warning(warning_hash)
        on_warning.call(warning_hash)
      end

      def stderr_warning(message)
        stderr.puts(message)
      end

      def breach_stop(reason)
        on_breach_stop.call(reason)
      end
    end

    class State
      def initialize
        @consecutive_breaches = 0
        @sleeping = false
        @failure = nil
        @mutex = Mutex.new
      end

      def with_sleeping
        @mutex.synchronize { @sleeping = true }
        yield
      ensure
        @mutex.synchronize { @sleeping = false }
      end

      def sleeping?
        @mutex.synchronize { @sleeping }
      end

      def increment_breaches
        @mutex.synchronize do
          @consecutive_breaches += 1
        end
      end

      def reset_breaches
        @mutex.synchronize do
          @consecutive_breaches = 0
        end
      end

      def record_failure(error)
        @mutex.synchronize do
          @failure ||= error
        end
      end

      def clear_failure
        @mutex.synchronize do
          error = @failure
          @failure = nil
          error
        end
      end
    end

    def initialize(sampler:, config:, stop_flag:, sleeper:, sink:)
      @sampler = sampler
      @config = config
      @stop_flag = stop_flag
      @sleeper = sleeper
      @sink = sink
      @state = State.new
    end

    def start
      return nil if @config.off?
      return nil if @sampler.nil?

      Thread.new do
        begin
          loop do
            break if @stop_flag.call

            begin
              Thread.handle_interrupt(Shutdown => :immediate) do
                @state.with_sleeping do
                  @sleeper.call(@config.interval_seconds)
                end
              end
            rescue Shutdown, StopIteration
              break
            end

            break if @stop_flag.call

            Thread.handle_interrupt(Shutdown => :never) do
              sample_once
            end
          end
        rescue Shutdown, StopIteration
          nil
        rescue StandardError => error
          @state.record_failure(error)
          @sink.breach_stop(:invariant_sampler_failed)
        end
      end
    end

    def stop(thread)
      return unless thread
      return if thread == Thread.current

      if @state.sleeping?
        begin
          thread.raise(Shutdown.new)
        rescue ThreadError
          nil
        end
      end

      thread.join
      failure = @state.clear_failure
      raise Failure, "invariant sampler failed" if failure
    end

    def sample_once
      sample = @sampler.call
      @sink.sample(sample)

      unless sample.breach?
        @state.reset_breaches if @config.enforce?
        return sample
      end

      warning = sample.to_warning
      @sink.warning(warning)

      if @config.warn?
        @sink.stderr_warning("warning: invariant breach: #{sample.breaches.join('; ')}")
        return sample
      end

      consecutive_breaches = @state.increment_breaches
      @sink.breach_stop(:invariant_breach) if @config.enforce? && consecutive_breaches >= 3
      sample
    end
  end
end
