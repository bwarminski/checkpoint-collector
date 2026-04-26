# ABOUTME: Runs the invariant sampler thread and applies breach policy.
# ABOUTME: Emits samples, warnings, and stop signals without owning run-record schema.
require "thread"

module Load
  class InvariantMonitor
    Failure = Class.new(StandardError)
    Shutdown = Class.new(StandardError)

    def initialize(sampler:, policy:, interval_seconds:, stop_flag:, sleeper:, on_sample:, on_warning:, on_breach_stop:, stderr:)
      @sampler = sampler
      @policy = policy
      @interval_seconds = interval_seconds
      @stop_flag = stop_flag
      @sleeper = sleeper
      @on_sample = on_sample
      @on_warning = on_warning
      @on_breach_stop = on_breach_stop
      @stderr = stderr
      @consecutive_breaches = 0
      @sleeping = false
      @failure = nil
      @mutex = Mutex.new
    end

    def start
      return nil if @policy == :off
      return nil if @sampler.nil?

      Thread.new do
        begin
          loop do
            break if @stop_flag.call

            begin
              Thread.handle_interrupt(Shutdown => :immediate) do
                sleep_once
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
          record_failure(error)
          @on_breach_stop.call(:invariant_sampler_failed)
        end
      end
    end

    def stop(thread)
      return unless thread
      return if thread == Thread.current

      if sleeping?
        begin
          thread.raise(Shutdown.new)
        rescue ThreadError
          nil
        end
      end

      thread.join
      failure = clear_failure
      raise Failure, "invariant sampler failed" if failure
    end

    def sample_once
      sample = @sampler.call
      @on_sample.call(sample)
      return reset_breaches unless sample.breach?

      warning = sample.to_warning
      @on_warning.call(warning)
      @stderr.puts("warning: invariant breach: #{sample.breaches.join('; ')}") if @policy == :warn
      return sample if @policy == :warn

      consecutive_breaches = @mutex.synchronize do
        @consecutive_breaches += 1
      end
      @on_breach_stop.call(:invariant_breach) if consecutive_breaches >= 3
      sample
    end

    private

    def sleep_once
      @mutex.synchronize do
        @sleeping = true
      end
      @sleeper.call(@interval_seconds)
    ensure
      @mutex.synchronize do
        @sleeping = false
      end
    end

    def reset_breaches
      @mutex.synchronize do
        @consecutive_breaches = 0 if @policy == :enforce
      end
    end

    def sleeping?
      @mutex.synchronize { @sleeping }
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
end
