"""Disposable stock serve fixture. The app still uses its real production clients."""
from __future__ import annotations
import argparse
import errno
import json
import os
from pathlib import Path
import secrets
import signal
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from http.server import ThreadingHTTPServer


def write_configuration_once(path: Path, values: dict[str, str], stop: threading.Event) -> None:
    """Transfer fixture credentials to one reader without a regular file."""
    encoded = json.dumps(values).encode()
    while not stop.is_set():
        try:
            descriptor = os.open(path, os.O_WRONLY | os.O_NONBLOCK)
        except OSError as error:
            if error.errno != errno.ENXIO:
                raise
            stop.wait(0.05)
            continue
        os.set_blocking(descriptor, True)
        with os.fdopen(descriptor, "wb") as pipe:
            pipe.write(encoded)
        return


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--python", type=Path, required=True)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--plugin", type=Path, help="bighelp-plugin checkout (default: a sibling of --repo)")
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--expected-sha", required=True)
    parser.add_argument("--auth-mode", choices=["password", "dashboard", "token"], default="password")
    args = parser.parse_args()
    source = args.source.resolve()
    repo = args.repo.resolve()
    assert len(args.expected_sha) == 40 and all(c in "0123456789abcdef" for c in args.expected_sha)
    assert subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip() == args.expected_sha
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from DirectHermesStreamingProbe import SyntheticModel
    from DirectHermesAuthenticationProbe import exercise_http

    stop = threading.Event()
    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, lambda *_: stop.set())
    args.root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="owned-stock-", dir=args.root) as temporary:
        root = Path(temporary).resolve()
        home = root / "home"
        project = root / "project"
        scratch = root / "tmp"
        for directory in (home, project, scratch):
            directory.mkdir(mode=0o700)
        model = ThreadingHTTPServer(("127.0.0.1", 0), SyntheticModel)
        threading.Thread(target=model.serve_forever, daemon=True).start()
        relay_attempts = []

        class RejectRelay(socketserver.BaseRequestHandler):
            def handle(self):
                relay_attempts.append(time.monotonic())
                self.request.settimeout(1)
                try:
                    self.request.recv(1024)
                except (TimeoutError, OSError):
                    pass

        relay = socketserver.ThreadingTCPServer(("127.0.0.1", 0), RejectRelay)
        relay.daemon_threads = True
        threading.Thread(target=relay.serve_forever, daemon=True).start()
        config = {
            "dashboard": {"public_url": "http://native-fixture.invalid"},
            "model": {"default": "fixture-model", "provider": "custom",
                      "base_url": f"http://127.0.0.1:{model.server_port}/v1", "api_key": "unused-by-the-local-synthetic-model"},
            "agent": {"max_turns": 3},
            "terminal": {"backend": "local", "cwd": str(project)},
            "plugins": {"enabled": ["loopdy"]},
            "memory": {"memory_enabled": False, "user_profile_enabled": False},
            "ui_meta": {"hermes-bots": {"title": "Native fixture"}},
        }
        (home / "plugins").mkdir()
        plugin = args.plugin or repo.parent / "bighelp-plugin"
        if not (plugin / "plugin.yaml").is_file():
            raise SystemExit(f"{plugin} is not a bighelp-plugin checkout; pass --plugin")
        # Hermes installs the plugin under its plugin id, "loopdy".
        (home / "plugins/loopdy").symlink_to(plugin.resolve(), target_is_directory=True)
        if args.auth_mode in {"dashboard", "token"}:
            config.pop("dashboard")
        (home / "config.yaml").write_text(json.dumps(config))
        (home / "SOUL.md").write_text("Use only this disposable fixture and its local model.\n")
        password = secrets.token_urlsafe(24)
        env = {
            "PATH": "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": str(home), "HERMES_HOME": str(home), "TMPDIR": str(scratch),
            "PYTHONPATH": str(source), "PYTHONDONTWRITEBYTECODE": "1", "PYTHONUNBUFFERED": "1",
            "HERMES_DASHBOARD_BASIC_AUTH_USERNAME": "native-fixture",
            "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD": password,
            "HERMES_DASHBOARD_BASIC_AUTH_SECRET": secrets.token_urlsafe(48),
            "HERMES_DASHBOARD_SESSION_TOKEN": secrets.token_urlsafe(32),
            "HTTP_PROXY": "http://127.0.0.1:1", "HTTPS_PROXY": "http://127.0.0.1:1",
            "NO_PROXY": "127.0.0.1,localhost",
            # A code-folder chat otherwise gets Hermes' coding tool set without plugin tools.
            "HERMES_TUI_TOOLSETS": "hermes-cli,loopdy",
        }
        if args.auth_mode in {"dashboard", "token"}:
            for key in list(env):
                if key.startswith("HERMES_DASHBOARD_BASIC_AUTH_"):
                    env.pop(key)
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        origin = f"http://127.0.0.1:{port}"
        # Stock access logs may include one-use WebSocket credentials in URLs.
        # Keep this disposable host's output out of persistent logs.
        log = open(os.devnull, "wb")
        configuration_writer = None
        process = subprocess.Popen(
            [str(args.python), "-m", "hermes_cli.main", "serve", "--isolated", "--skip-build",
             "--host", "127.0.0.1", "--port", str(port)],
            cwd=project, env=env, stdout=log, stderr=log
        )
        try:
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError("Isolated stock host exited before readiness")
                try:
                    with urllib.request.urlopen(origin + "/api/health", timeout=1) as response:
                        health = json.load(response)
                        if response.status == 200 and health.get("ok") is True:
                            break
                except OSError:
                    pass
                time.sleep(0.1)
            else:
                raise RuntimeError("Isolated stock host readiness timed out")
            if args.auth_mode == "password":
                _, _, tokens = exercise_http(origin, "native-fixture", password)
                token = tokens["access_token"]
            else:
                assert health["auth_required"] is False
                token = env["HERMES_DASHBOARD_SESSION_TOKEN"]
            credential_file = root / "probe.fifo"
            os.mkfifo(credential_file, mode=0o600)
            configuration_writer = threading.Thread(
                target=write_configuration_once,
                args=(credential_file, {
                    "address": origin, "username": "native-fixture", "password": password,
                    "token": token, "auth_mode": args.auth_mode,
                    "link_origin": f"https://127.0.0.1:{relay.server_address[1]}",
                    "receipt_path": str(args.root / "ui-proof.json"), "workspace_path": str(project),
                }, stop), daemon=True,
            )
            configuration_writer.start()
            receipt = {"ready": True, "pid": process.pid, "address": origin,
                       "config": str(credential_file), "root": str(root), "source": args.expected_sha}
            (args.root / "running.json").write_text(json.dumps(receipt))
            print(json.dumps(receipt), flush=True)
            while not stop.wait(1):
                if process.poll() is not None:
                    raise RuntimeError("Isolated stock host exited")
                with SyntheticModel.observation_lock:
                    nonces = sorted(SyntheticModel.observed_nonces)
                (args.root / "traffic.json").write_text(json.dumps({
                    "relay_attempts": len(relay_attempts), "model_calls": SyntheticModel.calls,
                    "reaction_notes": SyntheticModel.reaction_notes,
                    "offered_tools": sorted(SyntheticModel.offered_tools),
                    "provider_nonces": nonces
                }))
        finally:
            stop.set()
            if configuration_writer is not None:
                configuration_writer.join(timeout=1)
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            log.close()
            model.shutdown()
            model.server_close()
            relay.shutdown()
            relay.server_close()
            (args.root / "final.json").write_text(json.dumps({
                "stopped": True, "relay_attempts": len(relay_attempts), "model_calls": SyntheticModel.calls,
                "provider_nonces": sorted(SyntheticModel.observed_nonces)
            }))
            (args.root / "running.json").unlink(missing_ok=True)


if __name__ == "__main__":
    main()
