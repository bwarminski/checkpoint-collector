# ABOUTME: Verifies parsing of Rails SQL comment metadata for collector events.
# ABOUTME: Covers extraction of controller action tags and source file locations.
require "minitest/autorun"
require_relative "../lib/query_comment_parser"
require_relative "support/env"

class QueryCommentParserTest < Minitest::Test
  def test_parses_controller_action_and_source
    comment = "/*application:demo,controller:todos,action:index,source_location:/app/controllers/todos_controller.rb:12*/"

    parsed = QueryCommentParser.parse(comment)

    assert_equal "/app/controllers/todos_controller.rb:12", parsed[:source_file]
  end

  def test_parses_live_rails_equals_format_without_source_location
    comment = "/*action='index',application='Demo',controller='todos'*/"

    parsed = QueryCommentParser.parse(comment)

    assert_nil parsed[:source_file]
  end

  def test_returns_nil_source_file_when_comment_is_missing
    parsed = QueryCommentParser.parse(nil)

    assert_nil parsed[:source_file]
  end

  def test_returns_nil_source_file_when_comment_has_no_metadata_fields
    parsed = QueryCommentParser.parse("/* plain comment, no key=value pairs */")

    assert_nil parsed[:source_file]
  end

  def test_returns_nil_source_file_when_only_controller_is_present
    parsed = QueryCommentParser.parse("/*controller:todos*/")

    assert_nil parsed[:source_file]
  end

  def test_ignores_malformed_parts_without_separator
    # Parts with no colon or equals sign should be silently ignored
    parsed = QueryCommentParser.parse("/*garbage,controller:todos,action:index*/")

    assert_nil parsed[:source_file]
  end
end
