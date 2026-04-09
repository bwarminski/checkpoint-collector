# ABOUTME: Verifies the collector compose stack matches the supported local runtime.
# ABOUTME: Guards the collector services against reintroducing dead Redpanda wiring.
require "minitest/autorun"

class ComposeStackTest < Minitest::Test
  def test_collector_stack_no_longer_mentions_redpanda
    compose = File.read(File.expand_path("../../docker-compose.yml", __dir__))

    refute_includes compose, "redpanda:"
    refute_includes compose, "REDPANDA_BROKERS"
  end

  def test_collector_image_no_longer_installs_redpanda_native_dependencies
    dockerfile = File.read(File.expand_path("../Dockerfile", __dir__))

    refute_includes dockerfile, "librdkafka-dev"
  end

  def test_postgres_image_bootstraps_init_scripts
    dockerfile = File.read(File.expand_path("../../postgres/Dockerfile", __dir__))

    assert_includes dockerfile, "COPY init/ /docker-entrypoint-initdb.d/"
  end

  def test_redpanda_consumer_runtime_is_removed
    refute File.exist?(File.expand_path("../lib/redpanda_consumer.rb", __dir__))
  end
end
