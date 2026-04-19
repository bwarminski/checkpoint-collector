# ABOUTME: Waits for the external demo app and drives concurrent requests against the missing-index endpoint.
# ABOUTME: Persists the last traffic window so later assertions can read the same execution interval.
require "fileutils"
require "json"
require "net/http"
require "thread"
require "time"
require "uri"

module Fixtures
  module MissingIndex
    class Drive
      def initialize(manifest:, options:, clock: -> { Time.now.utc }, sleeper: ->(seconds) { sleep(seconds) })
        @manifest = manifest
        @options = options
        @clock = clock
        @sleeper = sleeper
      end

      def run
        wait_until_up!

        start_time = @clock.call
        finish_at = start_time + @options.fetch(:seconds)
        request_count = 0
        mutex = Mutex.new

        threads = Array.new(@options.fetch(:concurrency)) do
          Thread.new do
            limiter = RateLimiter.new(@options.fetch(:rate), clock: @clock, sleeper: @sleeper)

            while @clock.call < finish_at
              request_endpoint
              mutex.synchronize { request_count += 1 }
              limiter.wait_turn
            end
          end
        end

        threads.each(&:join)

        write_last_run(start_time: start_time, end_time: @clock.call, request_count: request_count)
      end

      private

      def wait_until_up!
        deadline = @clock.call + 120

        until healthy?
          raise "Timed out waiting for #{@options.fetch(:base_url)}#{@manifest.health_endpoint}" if @clock.call >= deadline

          @sleeper.call(1)
        end
      end

      def healthy?
        response = Net::HTTP.get_response(URI.join(@options.fetch(:base_url), @manifest.health_endpoint))
        response.code.to_i == 200
      rescue Errno::ECONNREFUSED
        false
      end

      def request_endpoint
        Net::HTTP.get_response(URI.join(@options.fetch(:base_url), @manifest.request_path))
      end

      def write_last_run(start_time:, end_time:, request_count:)
        output_dir = @options.fetch(:output_dir, File.expand_path("../../../tmp", __dir__))
        FileUtils.mkdir_p(output_dir)
        File.write(
          File.join(output_dir, "fixture-last-run.json"),
          JSON.pretty_generate(
            start_ts: start_time.iso8601(3),
            end_ts: end_time.iso8601(3),
            request_count: request_count,
          ) + "\n"
        )
      end

      class RateLimiter
        def initialize(rate, clock:, sleeper:)
          @rate = rate
          @clock = clock
          @sleeper = sleeper
          @next_allowed_at = nil
        end

        def wait_turn
          return if @rate == "unlimited"

          now = @clock.call
          @next_allowed_at ||= now
          sleep_for = @next_allowed_at - now
          @sleeper.call(sleep_for) if sleep_for.positive?
          @next_allowed_at = [@next_allowed_at, now].max + (1.0 / @rate)
        end
      end
    end
  end
end
