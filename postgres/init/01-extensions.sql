-- ABOUTME: Enables the Postgres extensions required by the demo stack.
-- ABOUTME: Installs pg_stat_statements and HypoPG in the bootstrap database.
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS hypopg;
