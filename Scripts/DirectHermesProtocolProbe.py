"""Exercise stock Hermes's direct API in a credential-free loopback home.

No production server, profile, credentials, model invocation, or relay access.
Only reports protocol outcomes and timings; generated secrets are never printed.
Run with the installed Hermes Python and --hermes /absolute/path/to/hermes.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
from pathlib import Path
import secrets
import socket
import statistics
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

import websockets


def request_status(origin: str, token: str | None = None) -> tuple[int, dict]:
    request = urllib.request.Request(origin + "/api/status")
    if token:
        request.add_header("X-Hermes-Session-Token", token)
    try:
        with urllib.request.urlopen(request, timeout=1) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, {}


async def read_messages(ws, deadline: float):
    while time.monotonic() < deadline:
        raw = await asyncio.wait_for(ws.recv(), timeout=max(0.01, deadline - time.monotonic()))
        for line in raw.splitlines():
            if line.strip():
                yield json.loads(line)


async def probe(origin: str, token: str) -> dict:
    endpoint = origin.replace("http://", "ws://") + "/api/ws"
    rejected = False
    try:
        async with websockets.connect(endpoint + "?token=" + secrets.token_urlsafe(32)) as ws:
            await asyncio.wait_for(ws.recv(), timeout=3)
    except (websockets.exceptions.InvalidStatus, websockets.exceptions.ConnectionClosed):
        rejected = True
    assert rejected, "Wrong token was not rejected"

    received_events = []
    rpc_ms = []
    async with websockets.connect(endpoint + "?token=" + urllib.parse.quote(token), max_size=8_000_000) as ws:
        async for message in read_messages(ws, time.monotonic() + 20):
            event = message.get("params", {}).get("type") if message.get("method") == "event" else None
            if event:
                received_events.append(event)
            if event == "gateway.ready":
                break
        assert "gateway.ready" in received_events, "No authenticated gateway readiness"

        async def rpc(method: str, params: dict, number: int):
            started = time.perf_counter()
            await ws.send(json.dumps({"jsonrpc": "2.0", "id": number, "method": method, "params": params}))
            async for message in read_messages(ws, time.monotonic() + 20):
                event = message.get("params", {}).get("type") if message.get("method") == "event" else None
                if event:
                    received_events.append(event)
                if message.get("id") == number:
                    assert "error" not in message, f"{method} returned error code {message.get('error', {}).get('code')}"
                    rpc_ms.append((time.perf_counter() - started) * 1000)
                    return message["result"]
            raise AssertionError(f"{method} did not respond")

        created = await rpc("session.create", {}, 1)
        session_id = created.get("session_id") or created.get("id")
        assert isinstance(session_id, str) and session_id, "No native session identity"
        history = await rpc("session.history", {"session_id": session_id}, 2)
        assert isinstance(history, dict), "History result must be structured"
        catalog = await rpc("commands.catalog", {"session_id": session_id}, 3)
        assert isinstance(catalog, dict), "Command catalog must be structured"
        status = await rpc("session.status", {"session_id": session_id}, 4)
        assert isinstance(status, dict), "Session status must be structured"
        return {
            "wrong_token_rejected": rejected,
            "authenticated_websocket_ready": True,
            "native_session_create_history_catalog_status": True,
            "events_observed": sorted(set(received_events)),
            "rpc_round_trip_ms": [round(v, 2) for v in rpc_ms],
            "median_rpc_round_trip_ms": round(statistics.median(rpc_ms), 2),
            "scope": "isolated stock Hermes over loopback; no model, Tailscale or phone acceptance",
        }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--hermes", required=True)
    arguments = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="loopdy-direct-probe-", dir="/tmp") as directory:
        home = Path(directory).resolve()
        token = secrets.token_urlsafe(32)
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        environment = {key: os.environ[key] for key in ("PATH", "LANG", "TMPDIR") if key in os.environ}
        environment.update({"HOME": str(home), "HERMES_HOME": str(home),
                            "HERMES_DASHBOARD_SESSION_TOKEN": token, "PYTHONUNBUFFERED": "1"})
        process = subprocess.Popen(
            [arguments.hermes, "serve", "--host", "127.0.0.1", "--port", str(port), "--isolated", "--skip-build"],
            env=environment, cwd=home, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        try:
            origin = f"http://127.0.0.1:{port}"
            deadline = time.monotonic() + 45
            while True:
                if process.poll() is not None:
                    raise RuntimeError(f"Isolated server exited with status {process.returncode}")
                try:
                    code, _ = request_status(origin, token)
                    if code == 200:
                        break
                except (OSError, urllib.error.URLError):
                    pass
                if time.monotonic() >= deadline:
                    raise TimeoutError("Isolated stock server did not become ready")
                time.sleep(0.2)
            print(json.dumps(asyncio.run(probe(origin, token)), indent=2))
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)


if __name__ == "__main__":
    main()