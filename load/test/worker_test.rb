# ABOUTME: Verifies the worker records request outcomes into its metrics buffer.
# ABOUTME: Covers error handling when selection or action construction fails.
require_relative "test_helper"

FailingAction = Class.new(Load::Action) do
  def name
    :failing_action
  end

  def call
    raise RuntimeError, "boom"
  end
end

class WorkerTest < Minitest::Test
  Response = Struct.new(:code)

  def stop_after(count)
    calls = 0
    -> do
      calls += 1
      calls > count
    end
  end

  def test_worker_records_errors_without_raising
    selector = Object.new
    selector.define_singleton_method(:next) do
      Load::ActionEntry.new(FailingAction, 1)
    end

    buffer = Load::Metrics::Buffer.new
    worker = Load::Worker.new(worker_id: 2, selector:, buffer:, client: Object.new, ctx: { base_url: "http://127.0.0.1:3000" }, rng: Random.new(7), rate_limiter: Object.new.tap { |limiter| limiter.define_singleton_method(:wait_turn) {} }, stop_flag: stop_after(1))

    worker.run

    assert_equal 1, buffer.swap!.fetch(:failing_action).fetch(:errors_by_class).fetch("RuntimeError")
  end

  def test_worker_records_error_when_selector_raises_before_started_ns
    raising_selector = Object.new
    raising_selector.define_singleton_method(:next) do
      raise RuntimeError, "boom"
    end

    buffer = Load::Metrics::Buffer.new
    worker = Load::Worker.new(worker_id: 9, selector: raising_selector, buffer:, client: Object.new, ctx: {}, rng: Random.new(7), rate_limiter: Object.new.tap { |limiter| limiter.define_singleton_method(:wait_turn) {} }, stop_flag: stop_after(1))

    worker.run

    bucket = buffer.swap!.fetch(:unknown)
    assert_equal 1, bucket.fetch(:errors_by_class).fetch("RuntimeError")
    assert_equal 0, bucket.fetch(:latencies_ns).first
  end

  def test_worker_records_error_when_action_init_raises
    bad_action_class = Class.new(Load::Action) do
      def initialize(**)
        raise ArgumentError, "bad kwargs"
      end
    end

    selector = Object.new
    selector.define_singleton_method(:next) do
      Load::ActionEntry.new(bad_action_class, 1)
    end

    buffer = Load::Metrics::Buffer.new
    worker = Load::Worker.new(worker_id: 1, selector:, buffer:, client: Object.new, ctx: {}, rng: Random.new(7), rate_limiter: Object.new.tap { |limiter| limiter.define_singleton_method(:wait_turn) {} }, stop_flag: stop_after(1))

    worker.run

    assert_equal 1, buffer.swap!.fetch(:unknown).fetch(:errors_by_class).fetch("ArgumentError")
  end

  def test_worker_falls_back_to_unknown_when_action_name_raises
    bad_name_action = Class.new(Load::Action) do
      def name
        raise RuntimeError, "bad name"
      end

      def call
        raise RuntimeError, "boom"
      end
    end

    selector = Object.new
    selector.define_singleton_method(:next) do
      Load::ActionEntry.new(bad_name_action, 1)
    end

    buffer = Load::Metrics::Buffer.new
    worker = Load::Worker.new(worker_id: 3, selector:, buffer:, client: Object.new, ctx: {}, rng: Random.new(7), rate_limiter: Object.new.tap { |limiter| limiter.define_singleton_method(:wait_turn) {} }, stop_flag: stop_after(1))

    worker.run

    assert_equal 1, buffer.swap!.fetch(:unknown).fetch(:errors_by_class).fetch("RuntimeError")
  end
end
