# ABOUTME: Loads repo-root .env before collector tests run.
# ABOUTME: Preserves exported shell values and fills only missing test variables.
def load_env_file(path)
  return unless File.exist?(path)

  File.readlines(path, chomp: true).each do |line|
    parsed = parse_env_line(line)
    next unless parsed

    key, value = parsed
    ENV[key] ||= value
  end
end

def parse_env_line(line)
  stripped = line.strip
  return nil if stripped.empty? || stripped.start_with?("#")
  return nil unless stripped.include?("=")

  key, value = stripped.split("=", 2)
  [key.strip, value.strip]
end

load_env_file(File.expand_path("../../../.env", __dir__))
