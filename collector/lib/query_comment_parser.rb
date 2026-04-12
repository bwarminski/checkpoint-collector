# ABOUTME: Parses Rails SQL comment tags into source metadata for collector rows.
# ABOUTME: Extracts source file locations from metadata comments in raw query text.
class QueryCommentParser
  COMMENT_BLOCK_PATTERN = %r{/\*.*?\*/}m
  METADATA_MARKERS = %w[source_location: source_location=].freeze

  def self.parse_from_query(query_text)
    comment = query_text.to_s.scan(COMMENT_BLOCK_PATTERN).find do |block|
      METADATA_MARKERS.any? { |marker| block.include?(marker) }
    end
    parse(comment)
  end

  def self.parse(comment)
    pairs = comment.to_s.delete_prefix("/*").delete_suffix("*/").split(",").filter_map do |part|
      key, value =
        if part.include?(":")
          part.split(":", 2)
        elsif part.include?("=")
          part.split("=", 2)
        end

      next unless key && value

      [key.strip, normalize_value(value)]
    end.to_h

    {
      source_file: pairs["source_location"]
    }
  end

  def self.normalize_value(value)
    value.strip.delete_prefix("\\'").delete_suffix("\\'").delete_prefix("'").delete_suffix("'")
  end
end
