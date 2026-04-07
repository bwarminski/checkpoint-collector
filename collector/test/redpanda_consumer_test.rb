# ABOUTME: Verifies the Redpanda consumer normalizes Kafka payloads for collector inserts.
# ABOUTME: Covers the minimum event shape needed to preserve the ClickHouse read model.
require "minitest/autorun"
require_relative "../lib/redpanda_consumer"

class RedpandaConsumerTest < Minitest::Test
  def test_converts_kafka_payload_into_query_event_shape
    consumer = RedpandaConsumer.new(nil)
    event = consumer.normalize({
      "fingerprint" => "abc",
      "source_tag" => "todos#index",
      "sample_query" => "SELECT * FROM todos"
    })

    assert_equal "abc", event[:fingerprint]
    assert_equal "todos#index", event[:source_tag]
  end
end
