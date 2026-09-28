"""Runs the app's host sign-in tests against real, isolated stock Hermes hosts.

Each mode starts `hermes serve` from the given Hermes checkout with a throwaway
HOME and HERMES_HOME, then runs the matching HostSignInMatrixUITests:

  open      no sign-in (the dashboard's own session), or its session token
  password  Hermes's username/password provider: password, access token, and
            browser sign-in through Hermes's login page
  sso       password plus a self-hosted OpenID Connect provider, using a mock
            identity provider on loopback for single sign-on in the browser
  tools     no sign-in, with the bighelp plugin (--plugin) and a scripted model
            whose tool keeps running: the secure input pop-up, and steering
            while a tool runs (not part of the default modes)

HERMES_DISABLE_LAZY_INSTALLS=1 keeps Hermes from "finishing a source update"
into its checkout on first launch. Use a separate Hermes checkout anyway: never
the one your real Hermes runs from.

  python3 Scripts/HostSignInMatrixProbe.py --hermes /tmp/hermes/.venv/bin/hermes \\
      --simulator-id <udid> --derived-data /tmp/dd --results /tmp/signin
"""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, str(Path(__file__).resolve().parent))
from DirectHermesProtocolProbe import request_status  # noqa: E402
from DirectHermesStreamingProbe import SyntheticModel  # noqa: E402
from DirectHermesAuthenticationProbe import exercise_http  # noqa: E402

TESTS = {
    "open": ["testOpenHostPrefersNoSignIn", "testOpenHostAcceptsItsSessionToken"],
    "password": ["testPasswordOnlyHostPrefersUsernameAndPasswordAndChats", "testWrongPasswordIsExplained",
                 "testAccessToken", "testBrowserSignInThroughHermesLoginPage"],
    "sso": ["testSingleSignOnThroughIdentityProvider"],
    "tools": ["testSecureInputPopUpSavesTheValue", "testSteerSendsWhileAToolRuns",
              "testWaitingQuestionOpensFocusedWhenReturningToTheApp"],
}
STEER_OPEN = "[OUT-OF-BAND USER MESSAGE"


class ToolTurnModel(BaseHTTPRequestHandler):
    """A scripted model whose tool keeps running. "secure input test" asks for a secret with
    bighelp's tool, which waits for the pop-up; "long tool test" runs a 20-second command so a
    steer lands mid-tool. The final reply says what the tool returned and any steer it got."""

    def log_message(self, *args):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        messages = request.get("messages", [])
        offered = {t.get("function", {}).get("name", "") for t in request.get("tools", [])}
        texts = [(i, str(m.get("content") or "")) for i, m in enumerate(messages) if m.get("role") == "user"]
        triggers = ("secure input test", "long tool test", "question test")
        start = max((i for i, text in texts if any(t in text for t in triggers)), default=-1)
        secure = start >= 0 and "secure input test" in messages[start].get("content", "")
        question = start >= 0 and "question test" in messages[start].get("content", "")
        results = [str(m.get("content") or "") for m in messages[start + 1:] if m.get("role") == "tool"]
        steers = [re.sub(r"^\[OUT-OF-BAND[^\]]*\]\s*|\s*\[/OUT-OF-BAND USER MESSAGE\]$", "", text.strip())
                  for i, text in texts if i > start and STEER_OPEN in text]
        call = None
        if start >= 0 and not results:
            name, arguments = (("bighelp_request_secure_input",
                                {"name": "SECURE_INPUT_FIXTURE", "label": "Fixture value",
                                 "prompt": "A test of the secure pop-up. Type anything."})
                               if secure else
                               ("clarify", {"question": "Which fixture option?", "choices": ["Alpha", "Beta"]})
                               if question else ("terminal", {"command": "sleep 20"}))
            if name not in offered and "tool_call" in offered:
                name, arguments = "tool_call", {"name": name, "arguments": arguments}
            call = {"id": "call_tool_turn_fixture", "type": "function",
                    "function": {"name": name, "arguments": json.dumps(arguments)}}
        if call:
            message = {"role": "assistant", "content": None, "tool_calls": [call]}
        else:
            if secure:
                outcome = json.loads(results[-1]) if results and results[-1].startswith("{") else {}
                text = "Secure input fixture: " + ("saved." if outcome.get("success") else
                                                   f"not saved ({outcome.get('error') or 'skipped' if outcome.get('skipped') else results[-1][:120]}).")
            elif question:
                text = "Question fixture answered: " + results[-1][:80]
            else:
                text = "Long tool fixture complete."
            if steers:
                text += " Steer received: " + " | ".join(steers)
            message = {"role": "assistant", "content": text}
        finish = "tool_calls" if call else "stop"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream" if request.get("stream") else "application/json")
        self.end_headers()
        if not request.get("stream"):
            self.wfile.write(json.dumps({"id": "fixture", "object": "chat.completion", "model": "fixture-model",
                "created": 1, "choices": [{"index": 0, "message": message, "finish_reason": finish}],
                "usage": {"prompt_tokens": 10, "completion_tokens": 10, "total_tokens": 20}}).encode())
            return
        delta = ({"role": "assistant", "tool_calls": [{**call, "index": 0}]} if call
                 else {"role": "assistant", "content": message["content"]})
        for part in (delta, {}):
            chunk = {"id": "fixture", "object": "chat.completion.chunk", "created": 1, "model": "fixture-model",
                     "choices": [{"index": 0, "delta": part, "finish_reason": None if part else finish}]}
            self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
            self.wfile.flush()
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


class MockIdentityProvider:
    """The smallest honest OpenID Connect provider: discovery, a login page
    with one button, PKCE-checked code exchange, RS256 ID tokens and JWKS."""

    def __init__(self, client_id: str):
        from cryptography.hazmat.primitives.asymmetric import rsa
        self.client_id = client_id
        self.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        self.kid = secrets.token_hex(8)
        self.codes: dict[str, dict] = {}
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), self._handler())
        self.issuer = f"http://127.0.0.1:{self.server.server_port}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def id_token(self) -> str:
        import jwt
        now = int(time.time())
        claims = {"iss": self.issuer, "aud": self.client_id, "sub": "sso-user-1", "email": "sso@example.com",
                  "name": "SSO Tester", "iat": now, "exp": now + 3600}
        return jwt.encode(claims, self.key, algorithm="RS256", headers={"kid": self.kid})

    def jwks(self) -> dict:
        numbers = self.key.public_key().public_numbers()
        def encode(value: int) -> str:
            return b64url(value.to_bytes((value.bit_length() + 7) // 8, "big"))
        return {"keys": [{"kty": "RSA", "use": "sig", "alg": "RS256", "kid": self.kid,
                          "n": encode(numbers.n), "e": encode(numbers.e)}]}

    def _handler(self):
        provider = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def send_json(self, status: int, value: dict):
                body = json.dumps(value).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                url = urllib.parse.urlparse(self.path)
                if url.path == "/.well-known/openid-configuration":
                    self.send_json(200, {
                        "issuer": provider.issuer,
                        "authorization_endpoint": provider.issuer + "/authorize",
                        "token_endpoint": provider.issuer + "/token",
                        "jwks_uri": provider.issuer + "/jwks",
                        "id_token_signing_alg_values_supported": ["RS256"],
                        "code_challenge_methods_supported": ["S256"],
                    })
                elif url.path == "/jwks":
                    self.send_json(200, provider.jwks())
                elif url.path == "/authorize":
                    query = urllib.parse.parse_qs(url.query)
                    fields = "".join(
                        f'<input type="hidden" name="{name}" value="{urllib.parse.quote(values[0])}">'
                        for name, values in query.items())
                    page = ('<!doctype html><meta name="viewport" content="width=device-width">'
                            '<title>Mock SSO</title><h1>Mock SSO</h1><form method="post" action="/approve">'
                            f'{fields}<button type="submit" style="font-size:24px">Approve sign-in</button></form>')
                    body = page.encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "text/html")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                else:
                    self.send_json(404, {"error": "not_found"})

            def do_POST(self):
                length = int(self.headers.get("Content-Length", "0"))
                form = {k: urllib.parse.unquote(v[0]) for k, v in
                        urllib.parse.parse_qs(self.rfile.read(length).decode()).items()}
                if self.path == "/approve":
                    assert form.get("client_id") == provider.client_id
                    code = secrets.token_urlsafe(24)
                    provider.codes[code] = {"challenge": form["code_challenge"], "redirect_uri": form["redirect_uri"]}
                    target = form["redirect_uri"] + "?" + urllib.parse.urlencode({"code": code, "state": form["state"]})
                    self.send_response(302)
                    self.send_header("Location", target)
                    self.end_headers()
                elif self.path == "/token":
                    if form.get("grant_type") == "authorization_code":
                        grant = provider.codes.pop(form.get("code", ""), None)
                        verifier = form.get("code_verifier", "")
                        if (grant is None or grant["redirect_uri"] != form.get("redirect_uri")
                                or b64url(hashlib.sha256(verifier.encode()).digest()) != grant["challenge"]):
                            self.send_json(400, {"error": "invalid_grant"})
                            return
                    elif form.get("grant_type") != "refresh_token":
                        self.send_json(400, {"error": "unsupported_grant_type"})
                        return
                    self.send_json(200, {"access_token": secrets.token_urlsafe(32), "id_token": provider.id_token(),
                                         "token_type": "Bearer", "expires_in": 3600,
                                         "refresh_token": secrets.token_urlsafe(32)})
                else:
                    self.send_json(404, {"error": "not_found"})

        return Handler

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def free_port() -> int:
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        return reservation.getsockname()[1]


def run_mode(mode: str, args, repo: Path) -> int:
    with tempfile.TemporaryDirectory(prefix=f"signin-{mode}-", dir="/tmp") as temporary:
        temp = Path(temporary).resolve()
        home, project = temp / "home", temp / "project"
        home.mkdir()
        project.mkdir()
        model = ThreadingHTTPServer(("127.0.0.1", 0), ToolTurnModel if mode == "tools" else SyntheticModel)
        threading.Thread(target=model.serve_forever, daemon=True).start()
        port = free_port()
        origin = f"http://127.0.0.1:{port}"
        # Hermes only gates a dashboard whose public address isn't loopback. *.localhost
        # still resolves to this Mac, so gated hosts use it; single sign-on needs the
        # app on that same name, since the sign-in cookie belongs to it.
        public = origin if mode in ("open", "tools") else f"http://hermes.localhost:{port}"
        config = {"dashboard": {"public_url": public},
                  "model": {"default": "fixture-model", "provider": "custom",
                            "base_url": f"http://127.0.0.1:{model.server_port}/v1", "api_key": "local-synthetic-no-auth"},
                  "agent": {"max_turns": 3}, "terminal": {"backend": "local", "cwd": str(project)},
                  "memory": {"memory_enabled": False, "user_profile_enabled": False}}
        if mode == "tools":
            if not args.plugin:
                raise SystemExit("tools mode needs --plugin <bighelp plugin folder>")
            shutil.copytree(args.plugin, home / "plugins" / "loopdy",
                            ignore=shutil.ignore_patterns("tests", "__pycache__", ".git"))
            config["agent"]["max_turns"] = 4
            config["plugins"] = {"enabled": ["loopdy"]}
        (home / "config.yaml").write_text(json.dumps(config))
        session_token, password = secrets.token_urlsafe(32), secrets.token_urlsafe(24)
        env = {k: os.environ[k] for k in ("PATH", "LANG", "TMPDIR") if k in os.environ}
        env.update(HOME=str(home), HERMES_HOME=str(home), HERMES_DISABLE_LAZY_INSTALLS="1",
                   HERMES_DASHBOARD_SESSION_TOKEN=session_token, PYTHONUNBUFFERED="1",
                   NO_PROXY="127.0.0.1,localhost")
        idp = None
        if mode in ("password", "sso"):
            env.update(HERMES_DASHBOARD_BASIC_AUTH_USERNAME="signin-fixture",
                       HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=password,
                       HERMES_DASHBOARD_BASIC_AUTH_SECRET=secrets.token_urlsafe(48))
        if mode == "sso":
            idp = MockIdentityProvider(client_id="bighelp-signin-test")
            env.update(HERMES_DASHBOARD_OIDC_ISSUER=idp.issuer, HERMES_DASHBOARD_OIDC_CLIENT_ID=idp.client_id)
        log = (args.results / f"hermes-{mode}.log").open("w")
        process = subprocess.Popen([args.hermes, "serve", "--host", "127.0.0.1", "--port", str(port), "--isolated",
                                    "--skip-build"], cwd=project, env=env, stdout=log, stderr=subprocess.STDOUT)
        secret = temp / "probe.json"
        try:
            deadline = time.monotonic() + 90
            while True:
                if process.poll() is not None:
                    raise RuntimeError(f"Hermes exited ({mode}); see hermes-{mode}.log")
                try:
                    if request_status(origin, session_token)[0] == 200:
                        break
                except OSError:
                    pass
                if time.monotonic() > deadline:
                    raise TimeoutError(f"Hermes not ready ({mode})")
                time.sleep(0.3)
            probe = {"mode": mode, "address": public.removeprefix("http://"), "session_token": session_token}
            if mode in ("password", "sso"):
                _, _, tokens = exercise_http(origin, "signin-fixture", password)
                probe.update(username="signin-fixture", password=password, token=tokens["access_token"])
            secret.write_text(json.dumps(probe))
            secret.chmod(0o600)
            client_env = dict(os.environ, TEST_RUNNER_BIGHELP_SIGNIN_PROBE=str(secret),
                              TEST_RUNNER_BIGHELP_SIGNIN_EVIDENCE=str(args.results / mode))
            (args.results / mode).mkdir(parents=True, exist_ok=True)
            command = ["xcodebuild", "test-without-building", "-project", str(repo / "Bighelp.xcodeproj"),
                       "-scheme", "Bighelp", "-destination", f"platform=iOS Simulator,id={args.simulator_id}",
                       "-derivedDataPath", str(args.derived_data), "-parallel-testing-enabled", "NO",
                       "-resultBundlePath", str(args.results / f"{mode}.xcresult")]
            command += [f"-only-testing:BighelpUITests/HostSignInMatrixUITests/{name}" for name in TESTS[mode]]
            with (args.results / f"xcodebuild-{mode}.log").open("w") as output:
                result = subprocess.run(command, env=client_env, cwd=repo, stdout=output, stderr=subprocess.STDOUT,
                                        timeout=1500)
            if mode == "tools":
                saved = (home / ".env").read_text() if (home / ".env").exists() else ""
                print(json.dumps({"secure_input_saved_on_host": "SECURE_INPUT_FIXTURE=" in saved}), flush=True)
            print(json.dumps({"mode": mode, "exit_code": result.returncode}), flush=True)
            return result.returncode
        finally:
            if (home / "logs").exists():
                shutil.copytree(home / "logs", args.results / f"hermes-{mode}-logs", dirs_exist_ok=True)
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            log.close()
            model.shutdown()
            model.server_close()
            if idp:
                idp.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--hermes", required=True, help="hermes executable from a separate, throwaway checkout")
    parser.add_argument("--simulator-id", required=True)
    parser.add_argument("--derived-data", type=Path, required=True)
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--modes", default="open,password,sso")
    parser.add_argument("--plugin", type=Path, help="bighelp (loopdy) plugin folder, for the tools mode")
    args = parser.parse_args()
    args.results.mkdir(parents=True, exist_ok=True)
    repo = Path(__file__).resolve().parents[1]
    failures = [mode for mode in args.modes.split(",") if run_mode(mode, args, repo) != 0]
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
