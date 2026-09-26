"""Verify stock gated-host password, bearer, refresh and WS-ticket authentication.

Uses only a disposable loopback server with generated credentials and a fake
public URL to engage the documented auth gate. No public listener or model.
"""
import argparse
import asyncio
import base64
import hashlib
import http.cookiejar
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import websockets
from websockets.typing import Subprotocol
from DirectHermesProtocolProbe import request_status


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def exercise_http(origin, username, password):
    opener = urllib.request.build_opener(NoRedirect(), urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
    def fetch(path, body=None, bearer=None):
        headers = {"Accept": "application/json"}
        if body is not None:
            headers["Content-Type"] = "application/json"
        if bearer:
            headers["Authorization"] = "Bearer " + bearer
        request = urllib.request.Request(origin + path, data=json.dumps(body).encode() if body is not None else None, headers=headers)
        try:
            response = opener.open(request, timeout=10)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            raw = response.read()
            value = json.loads(raw) if response.headers.get("Content-Type", "").startswith("application/json") else {}
            return response.code, value

    status, providers = fetch("/api/auth/providers")
    assert status == 200 and any(p["name"] == "basic" for p in providers["providers"])
    status, _ = fetch("/api/auth/me", bearer=secrets.token_urlsafe(32))
    assert status == 401, "Wrong remote bearer must be rejected"
    status, _ = fetch("/auth/password-login", {"provider": "basic", "username": username, "password": secrets.token_urlsafe(32)})
    assert status == 401, "Wrong password must be rejected"
    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    state = secrets.token_urlsafe(24)
    callback = "http://127.0.0.1:43219/direct-callback"
    query = urllib.parse.urlencode({"provider": "basic", "code_challenge": challenge, "code_challenge_method": "S256",
                                   "redirect_uri": callback, "state": state})
    status, _ = fetch("/auth/native/authorize?" + query)
    assert status == 302, "Expected native password challenge"
    status, login = fetch("/auth/password-login", {"provider": "basic", "username": username, "password": password})
    assert status == 200 and login.get("ok") is True
    redirect = urllib.parse.urlsplit(login["next"])
    assert urllib.parse.urlunsplit(redirect._replace(query="")) == callback
    query = urllib.parse.parse_qs(redirect.query)
    assert query["state"] == [state]
    status, tokens = fetch("/auth/native/token", {"code": query["code"][0], "code_verifier": verifier})
    assert status == 200 and tokens.get("access_token") and tokens.get("refresh_token")
    status, identity = fetch("/api/auth/me", bearer=tokens["access_token"])
    assert status == 200 and identity["user_id"] == username
    status, ticket = fetch("/api/auth/ws-ticket", {}, bearer=tokens["access_token"])
    assert status == 200 and ticket.get("ticket")
    status, refreshed = fetch("/auth/native/refresh", {"provider": "basic", "refresh_token": tokens["refresh_token"]})
    assert status == 200 and refreshed.get("access_token")
    return ticket["ticket"], {"wrong_password_rejected": True, "wrong_bearer_rejected": True,
                               "password_pkce_exchange": True, "bearer_identity": True,
                               "refresh": True, "ws_ticket_minted": True}, refreshed


async def exercise_ws(origin, ticket, legacy_token):
    endpoint = origin.replace("http://", "ws://") + "/api/ws"
    async with websockets.connect(endpoint, subprotocols=[Subprotocol("hermes-gateway-v1"), Subprotocol("hermes-gateway-ticket." + ticket)]) as ws:
        assert ws.subprotocol == "hermes-gateway-v1"
        raw = await asyncio.wait_for(ws.recv(), timeout=20)
        assert any(json.loads(line).get("params", {}).get("type") == "gateway.ready" for line in raw.splitlines())
    for suffix, protocols in [("", [Subprotocol("hermes-gateway-v1"), Subprotocol("hermes-gateway-ticket." + ticket)]),
                               ("?token=" + legacy_token, None)]:
        rejected = False
        try:
            async with websockets.connect(endpoint + suffix, subprotocols=protocols) as ws:
                await asyncio.wait_for(ws.recv(), timeout=3)
        except (websockets.exceptions.InvalidStatus, websockets.exceptions.ConnectionClosed):
            rejected = True
        assert rejected, "Gated host accepted reused ticket or legacy token"
    return {"authenticated_native_websocket": True, "ticket_reuse_rejected": True, "legacy_token_rejected_on_gated_host": True}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--hermes", required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="direct-auth-", dir="/tmp") as directory:
        home = Path(directory).resolve()
        (home / "config.yaml").write_text(json.dumps({"dashboard": {"public_url": "http://direct-fixture.invalid"}, "plugins": {"enabled": []}}))
        token, password = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        env = {k: os.environ[k] for k in ("PATH", "LANG", "TMPDIR") if k in os.environ}
        env.update(HOME=str(home), HERMES_HOME=str(home), HERMES_DASHBOARD_SESSION_TOKEN=token,
                   HERMES_DASHBOARD_BASIC_AUTH_USERNAME="direct-fixture", HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=password,
                   HERMES_DASHBOARD_BASIC_AUTH_SECRET=secrets.token_urlsafe(48), PYTHONUNBUFFERED="1")
        process = subprocess.Popen([args.hermes, "serve", "--host", "127.0.0.1", "--port", str(port), "--isolated", "--skip-build"],
                                   cwd=home, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            origin = f"http://127.0.0.1:{port}"
            deadline = time.monotonic() + 45
            while True:
                if process.poll() is not None:
                    raise RuntimeError("Isolated auth server exited")
                try:
                    if request_status(origin, token)[0] == 200:
                        break
                except OSError:
                    pass
                if time.monotonic() >= deadline:
                    raise TimeoutError("Server readiness")
                time.sleep(0.2)
            ticket, result, _ = exercise_http(origin, "direct-fixture", password)
            result.update(asyncio.run(exercise_ws(origin, ticket, token)))
            print(json.dumps({"outcome": "passed", "scope": "isolated stock gated host over loopback", **result}, indent=2))
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == "__main__":
    main()
