# ABOUTME: Verifies parsing of Rails SQL comment metadata for collector events.
# ABOUTME: Extracts key-value pairs from SQL comment blocks.
require "minitest/autorun"
require_relative "../lib/query_comment_parser"

class QueryCommentParserTest < Minitest::Test
  def test_parses_all_key_value_pairs_from_comment_blocks
    comment = "/*application:demo,controller:todos,action:index,source_location:/app/controllers/todos_controller.rb:12*/"

    parsed = QueryCommentParser.parse_from_query("SELECT 1 #{comment}")

    assert_equal(
      {
        "application" => "demo",
        "controller" => "todos",
        "action" => "index",
        "source_location" => "/app/controllers/todos_controller.rb:12"
      },
      parsed
    )
  end

  def test_last_duplicate_key_wins
    parsed = QueryCommentParser.parse_from_query(
      "SELECT 1 /*controller:todos*/ /*controller:archived_todos,action:index*/"
    )

    assert_equal(
      {
        "controller" => "archived_todos",
        "action" => "index"
      },
      parsed
    )
  end

  def test_returns_empty_hash_when_no_metadata_is_present
    assert_equal({}, QueryCommentParser.parse_from_query("SELECT 1"))
  end
end
