# Journal

- Task 2 uses a root override in `Fixtures::Manifest.load` so tests can write temp fixture trees without touching repo fixtures.
- `Fixtures::Command` accepts `manifest_loader:` so command parsing can be tested without requiring real fixture implementations.
- `bin/fixture` is the top-level entrypoint and should stay thin; fixture behavior belongs under `collector/lib/fixtures/` and `fixtures/`.
- Task 2 command dispatch should treat handler failures as runtime errors, not usage errors.
- Invalid `--rate` input should be converted into an `OptionParser` parse error so the CLI prints usage instead of crashing.
