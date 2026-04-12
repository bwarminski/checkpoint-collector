# ABOUTME: Runs collector work on fixed wall-clock interval boundaries.
# ABOUTME: Serializes runs, skips missed slots after overruns, and logs failures.
class Scheduler
  def initialize(interval_seconds:, clock:, sleep_until:, stderr:, run_once:)
    @interval_seconds = interval_seconds
    @clock = clock
    @sleep_until = sleep_until
    @stderr = stderr
    @run_once = run_once
  end

  def run_forever
    loop do
      run_iteration
    end
  end

  def run_iterations(count)
    count.times do
      run_iteration
    end
  end

  private

  def run_iteration
    current_time = @clock.call
    scheduled_time = next_boundary(current_time)
    @sleep_until.call(scheduled_time) if scheduled_time > current_time
    @run_once.call
  rescue StandardError => error
    @stderr.puts(error.message)
  end

  def next_boundary(time)
    seconds = time.to_i
    remainder = seconds % @interval_seconds
    return time if remainder.zero?

    Time.at(seconds + (@interval_seconds - remainder)).utc
  end
end
