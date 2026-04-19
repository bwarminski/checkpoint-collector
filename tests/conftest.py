# ABOUTME: Shared pytest fixtures for collector integration tests.
# ABOUTME: Provides compose stack lifecycle helpers used across smoke test modules.
import json
import os
import subprocess
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
COMPOSE_ENV = {**os.environ, "COMPOSE_PROJECT_NAME": "checkpoint-collector"}


def compose(*args, **kwargs):
    return subprocess.run(
        ["docker", "compose", *args],
        cwd=ROOT,
        env=kwargs.pop("env", COMPOSE_ENV),
        check=kwargs.pop("check", True),
        capture_output=kwargs.pop("capture_output", True),
        text=kwargs.pop("text", True),
        **kwargs,
    )


def wait_healthy(service: str, timeout: int = 60) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        ps = compose("ps", "--format", "json", service)
        container = json.loads(ps.stdout) if ps.stdout.strip() else {}
        if isinstance(container, list):
            container = container[0] if container else {}
        health = container.get("Health", "")
        state = container.get("State", "")
        if state and state not in ("running", ""):
            logs = compose("logs", service).stdout
            raise AssertionError(f"{service} entered state {state!r}\n{logs}")
        if health == "healthy":
            return
        time.sleep(1)
    logs = compose("logs", service).stdout
    raise AssertionError(f"{service} did not become healthy within {timeout}s\n{logs}")


def clickhouse_query(sql: str) -> str:
    result = compose(
        "exec", "-T", "clickhouse",
        "clickhouse-client", "--query", sql,
    )
    return result.stdout.strip()


def postgres_exec(sql: str) -> str:
    result = compose(
        "exec", "-T", "postgres",
        "psql", "-U", "postgres", "-d", "checkpoint_demo", "-t", "-c", sql,
    )
    return result.stdout.strip()
