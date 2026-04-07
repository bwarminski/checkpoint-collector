# Load Harness

This directory contains a small Ruby harness that cycles through the demo app endpoints:

- `/todos`
- `/todos?q=task`
- `/todos/status`
- `/todos/stats`

Run it with:

```bash
ruby load/harness.rb
```

Set `BASE_URL` to point at a different demo instance if needed.
