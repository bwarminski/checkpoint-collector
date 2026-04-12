# TODO

- [ ] Build a project-scoped `/qa` skill for this repo. The gstack `/qa` skill is web-browser-only. This project needs a Ruby-native QA workflow: run the full test suite, check schema SQL files against the running ClickHouse container, and verify the compose stack starts clean. Scope: unit tests + schema smoke + compose up/down. Model after gstack's tier system (quick = unit tests only, standard = + schema smoke, exhaustive = + full compose cycle).
