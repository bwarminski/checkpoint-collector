# ABOUTME: Builds the collector image used in the local compose stack.
# ABOUTME: Installs the native libraries needed for Postgres-backed ingestion.
FROM ruby:3.2.3

WORKDIR /app

RUN apt-get update \
    && apt-get install -y build-essential libpq-dev \
    && rm -rf /var/lib/apt/lists/*

COPY Gemfile ./
RUN bundle install

COPY . .
