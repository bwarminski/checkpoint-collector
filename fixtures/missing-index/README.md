# Missing Index Fixture

This fixture reproduces the broken `todos.status` plan against the external demo app.

## Oracle Tags

- `oracle/rewrite-like` rewrites the text search path in the demo repo.
- `oracle/add-index` adds the missing `todos(status)` index and flips the root node from `Seq Scan` to `Index Scan`.
- `oracle/rewrite-count` changes the stats query path.

## Demo App Startup

Start the collector stack in `checkpoint-collector`, then start the demo app separately:

```bash
DATABASE_URL=postgres://postgres:postgres@localhost:5432/fixture_01 ~/db-specialist-demo/bin/rails server
```

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
