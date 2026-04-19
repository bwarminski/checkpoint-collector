-- ABOUTME: Creates the missing-index fixture schema with the todos status column left unindexed.
-- ABOUTME: Leaves the users_id and todos.user_id relationship in place so the reset path can seed data.
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

CREATE TABLE users (
  id BIGSERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  created_at TIMESTAMP NOT NULL,
  updated_at TIMESTAMP NOT NULL
);

CREATE TABLE todos (
  id BIGSERIAL PRIMARY KEY,
  title TEXT NOT NULL,
  status TEXT NOT NULL,
  user_id BIGINT NOT NULL REFERENCES users(id),
  created_at TIMESTAMP NOT NULL,
  updated_at TIMESTAMP NOT NULL
);

CREATE INDEX index_todos_on_user_id ON todos (user_id);
