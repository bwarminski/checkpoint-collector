# ABOUTME: Parses Rails SQL comment tags into source metadata for collector rows.
# ABOUTME: Extracts key-value metadata from comment blocks in raw query text.
class QueryCommentParser
  COMMENT_PATTERN = %r{/\*(.*?)\*/}m.freeze
  PAIR_PATTERN = /\A([A-Za-z0-9_]+)\s*[:=]\s*(.+)\z/.freeze

  def self.parse_from_query(query_text)
    return {} if query_text.nil?

    query_text.scan(COMMENT_PATTERN).each_with_object({}) do |(body), pairs|
      body.to_s.split(",").each do |part|
        token = part.to_s.strip
        next if token.empty?

        match = token.match(PAIR_PATTERN)
        next unless match

        pairs[match[1]] = normalize_value(match[2])
      end
    end
  end

  def self.parse(comment)
    parse_from_query(comment)
  end

  def self.normalize_value(value)
    value.strip.delete_prefix("\\'").delete_suffix("\\'").delete_prefix("'").delete_suffix("'")
  end
end
