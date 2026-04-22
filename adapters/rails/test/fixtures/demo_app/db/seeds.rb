# ABOUTME: Seeds the fixture integration app with a tiny benchmark dataset.
# ABOUTME: Uses the same env-driven contract as the real demo app seed path.
rows_per_table = Integer(ENV.fetch("ROWS_PER_TABLE", "10"))
seed_value = Integer(ENV.fetch("SEED", "42"))
open_fraction = Float(ENV.fetch("OPEN_FRACTION", "0.2"))

ActiveRecord::Base.connection.execute(<<~SQL)
  DELETE FROM fixture_records;
  INSERT INTO fixture_records (label, created_at, updated_at)
  SELECT 'seed-' || #{seed_value} || '-' || i || '-' || #{open_fraction}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
  FROM generate_series(1, #{rows_per_table}) AS i;
SQL
