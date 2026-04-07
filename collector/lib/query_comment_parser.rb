# ABOUTME: Parses Rails SQL comment tags into source metadata for collector rows.
# ABOUTME: Extracts controller-action tags and source file locations from comments.
class QueryCommentParser
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
      source_tag: [pairs["controller"], pairs["action"]].compact.join("#"),
      source_file: pairs["source_location"]
    }
  end

  def self.normalize_value(value)
    value.strip.delete_prefix("\\'").delete_suffix("\\'").delete_prefix("'").delete_suffix("'")
  end
end
