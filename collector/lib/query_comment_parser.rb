# ABOUTME: Parses Rails SQL comment tags into source metadata for collector rows.
# ABOUTME: Extracts key-value metadata from comment blocks in raw query text.
class QueryCommentParser
  PAIR_PATTERN = /\A([A-Za-z0-9_]+)\s*[:=]\s*(.*)\z/.freeze

  def self.parse_from_query(query_text)
    return {} if query_text.nil?

    comment_bodies(query_text).each_with_object({}) do |body, pairs|
      body.to_s.split(/,(?=\s*[A-Za-z0-9_]+\s*[:=])/).each do |part|
        token = part.to_s.strip
        next if token.empty?

        match = token.match(PAIR_PATTERN)
        next unless match

        pairs[match[1]] = normalize_value(match[2])
      end
    end
  end

  def self.comment_bodies(query_text)
    bodies = []
    index = 0

    while index < query_text.length
      if query_text[index] == "'"
        index = advance_past_string_literal(query_text, index)
        next
      end

      if query_text[index, 2] == "/*"
        end_index = query_text.index("*/", index + 2)
        break unless end_index

        bodies << query_text[(index + 2)...end_index]
        index = end_index + 2
        next
      end

      index += 1
    end

    bodies
  end

  def self.advance_past_string_literal(query_text, index)
    index += 1

    while index < query_text.length
      if query_text[index] == "'"
        if query_text[index + 1] == "'"
          index += 2
          next
        end

        return index + 1
      end

      index += 1
    end

    query_text.length
  end

  def self.normalize_value(value)
    value.strip.delete_prefix("\\'").delete_suffix("\\'").delete_prefix("'").delete_suffix("'")
  end
end
