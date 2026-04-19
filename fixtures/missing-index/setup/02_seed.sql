-- ABOUTME: Seeds the missing-index fixture with a large todos table and a rare open status.
-- ABOUTME: Analyzes both tables so the planner can choose the intended seq scan baseline.
INSERT INTO users (name, created_at, updated_at)
SELECT 'user_' || i, NOW(), NOW()
FROM generate_series(1, 1000) AS i;

INSERT INTO todos (title, status, user_id, created_at, updated_at)
SELECT
  'todo ' || i,
  CASE WHEN random() < 0.998 THEN 'closed' ELSE 'open' END,
  (random() * 999 + 1)::int,
  NOW(),
  NOW()
FROM generate_series(1, 10000000) AS i;

ANALYZE users;
ANALYZE todos;
