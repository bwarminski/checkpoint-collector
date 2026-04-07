# ABOUTME: Verifies lookup of sample SQL text from active Postgres sessions.
# ABOUTME: Covers the query text returned for a matching pg_stat_activity query ID.
require "minitest/autorun"
require_relative "../lib/sample_query_lookup"

class SampleQueryLookupTest < Minitest::Test
  def test_returns_sample_query_for_queryid
    connection = FakeConnection.new([{ "query" => "SELECT * FROM todos /*application:demo,controller:todos,action:index,source_location:/app/controllers/todos_controller.rb:12*/" }])

    lookup = SampleQueryLookup.new(connection)

    assert_equal "SELECT * FROM todos /*application:demo,controller:todos,action:index,source_location:/app/controllers/todos_controller.rb:12*/", lookup.find_for(42)
    assert_equal "SELECT query FROM pg_stat_activity WHERE query_id = $1 LIMIT 1", connection.sql
    assert_equal [42], connection.params
  end

  class FakeConnection
    attr_reader :sql, :params

    def initialize(result)
      @result = result
    end

    def exec_params(sql, params)
      @sql = sql
      @params = params
      @result
    end
  end
end
