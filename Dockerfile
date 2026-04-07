# ABOUTME: Builds the ClickHouse image used by the slim checkpoint stack.
# ABOUTME: Copies the schema bootstrap SQL and user config into the image.
FROM clickhouse/clickhouse-server:24.3

COPY clickhouse/users.d/default-user.xml /etc/clickhouse-server/users.d/default-user.xml
COPY collector/db/clickhouse/*.sql /docker-entrypoint-initdb.d/
