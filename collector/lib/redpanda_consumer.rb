# ABOUTME: Normalizes Redpanda message payloads into collector query event hashes.
# ABOUTME: Preserves the existing ClickHouse read model while Phase 2 transport is added.
class RedpandaConsumer
  def initialize(client)
    @client = client
  end

  def normalize(payload)
    {
      fingerprint: payload.fetch("fingerprint"),
      sample_query: payload["sample_query"]
    }
  end
end
