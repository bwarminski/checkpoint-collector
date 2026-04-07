# ABOUTME: Retrieves representative SQL text for a pg_stat_statements query ID.
# ABOUTME: Uses pg_stat_activity to capture one live sample query when available.
class SampleQueryLookup
  def initialize(connection)
    @connection = connection
  end

  def find_for(queryid)
    @connection.exec_params("SELECT query FROM pg_stat_activity WHERE query_id = $1 LIMIT 1", [queryid]).first&.fetch("query", nil)
  end
end
