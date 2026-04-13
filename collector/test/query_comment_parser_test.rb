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

  def test_parses_values_that_contain_commas
    parsed = QueryCommentParser.parse_from_query(
      "SELECT 1 /*note:hello, world,source_location:/app/a,b.rb:12*/"
    )

    assert_equal(
      {
        "note" => "hello, world",
        "source_location" => "/app/a,b.rb:12"
      },
      parsed
    )
  end

  def test_parses_equal_separators_and_quoted_values_with_commas
    parsed = QueryCommentParser.parse_from_query(
      "SELECT 1 /*application='Demo',controller='todos',action='index',note='hello, world'*/"
    )

    assert_equal(
      {
        "application" => "Demo",
        "controller" => "todos",
        "action" => "index",
        "note" => "hello, world"
      },
      parsed
    )
  end

  def test_parses_mixed_separator_styles_in_one_comment_block
    parsed = QueryCommentParser.parse_from_query(
      "SELECT 1 /*application:demo,controller='todos',action=index*/"
    )

    assert_equal(
      {
        "application" => "demo",
        "controller" => "todos",
        "action" => "index"
      },
      parsed
    )
  end

  def test_ignores_comment_looking_text_inside_string_literals
    parsed = QueryCommentParser.parse_from_query(
      "SELECT '/*controller:todos,action:index*/' AS statement_text"
    )

    assert_equal({}, parsed)
  end

  def test_preserves_blank_metadata_values
    parsed = QueryCommentParser.parse_from_query(
      "SELECT 1 /*controller:,action:index*/"
    )

    assert_equal(
      {
        "controller" => "",
        "action" => "index"
      },
      parsed
    )
  end

  def test_returns_empty_hash_when_no_metadata_is_present
    assert_equal({}, QueryCommentParser.parse_from_query("SELECT 1"))
  end
end
