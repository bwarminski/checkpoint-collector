# ABOUTME: Verifies parsing of Rails SQL comment metadata for collector events.
# ABOUTME: Extracts only source file locations from metadata blocks.
require "minitest/autorun"
require_relative "../lib/query_comment_parser"

class QueryCommentParserTest < Minitest::Test
  def test_parses_source_location_comment
    comment = "/*application:demo,controller:todos,action:index,source_location:/app/controllers/todos_controller.rb:12*/"

    parsed = QueryCommentParser.parse(comment)

    assert_equal({ source_file: "/app/controllers/todos_controller.rb:12" }, parsed)
  end

  def test_returns_nil_source_file_when_source_location_missing
    comment = "/*action='index',application='Demo',controller='todos'*/"

    parsed = QueryCommentParser.parse(comment)

    assert_equal({ source_file: nil }, parsed)
  end

  def test_returns_nil_source_file_when_comment_is_missing
    parsed = QueryCommentParser.parse(nil)

    assert_equal({ source_file: nil }, parsed)
  end

  def test_returns_nil_source_file_when_comment_has_no_metadata_fields
    parsed = QueryCommentParser.parse("/* plain comment, no key=value pairs */")

    assert_equal({ source_file: nil }, parsed)
  end

  def test_returns_nil_source_file_when_only_controller_is_present
    parsed = QueryCommentParser.parse("/*controller:todos*/")

    assert_equal({ source_file: nil }, parsed)
  end

  def test_returns_nil_source_file_when_parts_are_malformed
    parsed = QueryCommentParser.parse("/*garbage,controller:todos,action:index*/")

    assert_equal({ source_file: nil }, parsed)
  end
end
