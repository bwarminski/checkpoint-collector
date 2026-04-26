# ABOUTME: Captures the Rails pg_stat_statements query IDs for the missing-index workload.
# ABOUTME: Warms the tenant-scoped open-todos query and emits JSON for the Rails adapter.
require "json"

user = User.first or raise("expected a seeded user")
user.todos.with_status("open").ordered_by_created_desc.page(1, 50).load
connection = ActiveRecord::Base.connection
query_ids = [
  %(SELECT "todos".* FROM "todos" WHERE "todos"."user_id" = $1 AND "todos"."status" = $2 ORDER BY "todos"."created_at" DESC, "todos"."id" DESC LIMIT $3 OFFSET $4),
].flat_map do |query_text|
  connection.exec_query(
    "SELECT DISTINCT queryid::text AS queryid FROM pg_stat_statements WHERE query = #{connection.quote(query_text)}"
  ).rows.flatten
end.uniq
$stdout.write(JSON.generate(query_ids: query_ids))
