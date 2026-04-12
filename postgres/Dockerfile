# ABOUTME: Builds the Postgres image used by the local demo stack.
# ABOUTME: Installs the extensions needed for the initial database scaffold.
FROM postgres:16
RUN apt-get update \
    && apt-get install -y postgresql-16-hypopg \
    && install -d -o postgres -g postgres /var/lib/postgresql/data/pg_log \
    && rm -rf /var/lib/apt/lists/*
COPY init/ /docker-entrypoint-initdb.d/
