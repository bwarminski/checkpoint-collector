# ABOUTME: Verifies the missing-index workload invariant sampler contract.
# ABOUTME: Covers isolated PG usage, named checks, healthy samples, and connection failures.
require_relative "../../../load/test/test_helper"
require_relative "../invariant_sampler"

class MissingIndexTodosInvariantSamplerTest < Minitest::Test
  def test_sampler_uses_isolated_pg_connection_and_returns_named_checks
    pg = FakePg.new(
      open_count: 35_000,
      total_count: 100_000,
    )
    sampler = Load::Workloads::MissingIndexTodos::InvariantSampler.new(
      pg:,
      database_url: "postgres://localhost/checkpoint_collector",
      open_floor: 30_000,
      total_floor: 80_000,
      total_ceiling: 200_000,
    )

    sample = sampler.call

    refute pg.shared_connection_used?, "sampler must not reuse the workload connection"
    assert_equal true, pg.connection.closed?
    assert_includes pg.connection.session_sql, Load::Workloads::MissingIndexTodos::InvariantSampler::DISABLE_TRACKING_SQL
    assert_equal ["open_count", "total_count"], sample.checks.map(&:name)
    assert_equal true, sample.healthy?
  end

  def test_sampler_propagates_pg_connection_failure
    pg = Object.new
    pg.define_singleton_method(:connect) do |_database_url|
      raise PG::ConnectionBad, "connect failed"
    end
    sampler = Load::Workloads::MissingIndexTodos::InvariantSampler.new(
      pg:,
      database_url: "postgres://localhost/checkpoint_collector",
      open_floor: 30_000,
      total_floor: 80_000,
      total_ceiling: 200_000,
    )

    error = assert_raises(PG::ConnectionBad) { sampler.call }

    assert_equal "connect failed", error.message
  end

  def test_sampler_returns_counts_when_tracking_cannot_be_disabled
    pg = FakePg.new(
      open_count: 35_000,
      total_count: 100_000,
      raise_tracking_permission: true,
    )
    sampler = Load::Workloads::MissingIndexTodos::InvariantSampler.new(
      pg:,
      database_url: "postgres://localhost/checkpoint_collector",
      open_floor: 30_000,
      total_floor: 80_000,
      total_ceiling: 200_000,
    )

    sample = sampler.call

    assert_includes pg.connection.session_sql, Load::Workloads::MissingIndexTodos::InvariantSampler::DISABLE_TRACKING_SQL
    assert_includes pg.connection.session_sql, Load::Workloads::MissingIndexTodos::InvariantSampler::OPEN_COUNT_SQL
    assert_includes pg.connection.session_sql, Load::Workloads::MissingIndexTodos::InvariantSampler::TOTAL_COUNT_SQL
    assert_equal ["open_count", "total_count"], sample.checks.map(&:name)
    assert_equal [35_000, 100_000], sample.checks.map(&:actual)
    assert_equal true, sample.healthy?
  end

  class FakePg
    attr_reader :connection

    def initialize(open_count:, total_count:, raise_tracking_permission: false)
      @open_count = open_count
      @total_count = total_count
      @raise_tracking_permission = raise_tracking_permission
      @shared_connection_used = false
      @connection = nil
    end

    def connect(database_url)
      @connection = FakePgConnection.new(
        database_url:,
        open_count: @open_count,
        total_count: @total_count,
        raise_tracking_permission: @raise_tracking_permission,
      )
    end

    def shared_connection
      @shared_connection_used = true
    end

    def shared_connection_used?
      @shared_connection_used
    end
  end

  class FakePgConnection
    attr_reader :session_sql

    def initialize(database_url:, open_count:, total_count:, raise_tracking_permission:)
      @database_url = database_url
      @open_count = open_count
      @total_count = total_count
      @raise_tracking_permission = raise_tracking_permission
      @session_sql = []
      @closed = false
    end

    def exec(sql)
      @session_sql << sql
      if @raise_tracking_permission && sql.include?("pg_stat_statements.track")
        raise PG::InsufficientPrivilege, "permission denied to set parameter \"pg_stat_statements.track\""
      elsif sql.include?("COUNT(*)") && sql.include?("FROM todos")
        [{ "count" => @open_count.to_s }]
      elsif sql.include?("FROM pg_class")
        [{ "count" => @total_count.to_s }]
      else
        []
      end
    end

    def transaction
      yield self
    end

    def close
      @closed = true
    end

    def closed?
      @closed
    end
  end
end
