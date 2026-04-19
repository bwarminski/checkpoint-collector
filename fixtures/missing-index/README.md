# Missing Index Fixture

This fixture reproduces the broken `todos.status` plan against the external demo app.

## Oracle Tags

- `oracle/rewrite-like` rewrites the text search path in the demo repo.
- `oracle/add-index` adds the missing `todos(status)` index and flips the root node from `Seq Scan` to `Index Scan`.
- `oracle/rewrite-count` changes the stats query path.

## Demo App Startup

Start the collector stack in `checkpoint-collector`, then start the demo app separately:

```bash
BUNDLE_USER_HOME=/tmp/bundle BUNDLE_PATH=vendor/bundle \
DATABASE_URL=postgres://postgres:postgres@localhost:5432/fixture_01 \
bundle exec rails server -b 127.0.0.1 -p 3000
```

Run that command from `~/db-specialist-demo`.

Before `bin/fixture missing-index drive` or `all`, verify the readiness probe:

```bash
curl -i http://127.0.0.1:3000/up
```

`bin/fixture` waits for `/up` to return `200`. On the current `ab679e7` baseline app, `/up`
returns `404`, so `drive` and `all` time out with a message that includes the last observed
health status.

## Commands

```bash
bin/fixture missing-index reset --rebuild-template
bin/fixture missing-index drive
bin/fixture missing-index assert
bin/fixture missing-index all
```

## Oracle Verification

`bin/fixture missing-index assert` reads `tmp/fixture-last-run.json`, so run
`drive` first or reuse an existing last-run file from the same fixture window.

```bash
bin/fixture missing-index reset --rebuild-template
bin/fixture missing-index drive
git -C ~/db-specialist-demo checkout oracle/add-index
bin/fixture missing-index assert --timeout-seconds 180
git -C ~/db-specialist-demo checkout master
```

The assertion should fail because the root node becomes `Index Scan`.
