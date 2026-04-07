# ABOUTME: Builds the Postgres image used by the local demo stack.
# ABOUTME: Installs the extensions needed for the initial database scaffold.
FROM postgres:16
RUN apt-get update \
    && apt-get install -y postgresql-16-hypopg \
    && rm -rf /var/lib/apt/lists/*
