"""Compile unchanged production Direct Swift networking against isolated stock Hermes.

Runs the Apple URLSession client, not a Python imitation. The only synthetic
part is the deliberately local model, which requests a real temporary `pwd`.
"""
import argparse
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer
from DirectHermesProtocolProbe import request_status
from DirectHermesStreamingProbe import SyntheticModel
from DirectHermesAuthenticationProbe import exercise_http
from PrivateProbeConfiguration import PrivateProbeConfiguration


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--hermes", required=True)
    parser.add_argument("--ios-tests", action="store_true")
    parser.add_argument("--only-testing", action="append", default=[])
    parser.add_argument("--simulator-id")
    parser.add_argument("--derived-data", type=Path)
    parser.add_argument("--result-root", type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="direct-native-", dir="/tmp") as temporary:
        temp = Path(temporary).resolve()
        value_source = (repo / "Bighelp/Chat/GenerativeUIModels.swift").read_text()
        separator = "\nenum GenerativeUIComponent:"
        assert separator in value_source
        # Exact production JSON value declaration, without unrelated app UI types.
        (temp / "BighelpJSONValue.swift").write_text(value_source.split(separator, 1)[0])
        sources = [repo / "Bighelp/DirectHermes" / (name + ".swift") for name in
                   ("DirectHermesInterfaces", "DirectHermesAuthentication", "DirectHermesNetworking", "DirectHermesCredentialVault")]
        executable = temp / "native-probe"
        if not args.ios_tests:
            subprocess.run(["swiftc", "-parse-as-library", "-swift-version", "6", "-target", "arm64-apple-macosx15.0",
                            *(str(p) for p in sources), str(temp / "BighelpJSONValue.swift"), str(repo / "Scripts/DirectHermesNativeProbe.swift"),
                            "-o", str(executable)], check=True)
        elif not all((args.simulator_id, args.derived_data, args.result_root)):
            parser.error("iOS tests require simulator-id, derived-data and result-root")
        model = ThreadingHTTPServer(("127.0.0.1", 0), SyntheticModel)
        threading.Thread(target=model.serve_forever, daemon=True).start()
        home, project = temp / "home", temp / "project"
        home.mkdir()
        project.mkdir()
        config = {"dashboard": {"public_url": "http://direct-fixture.invalid"},
                  "model": {"default": "fixture-model", "provider": "custom", "base_url": f"http://127.0.0.1:{model.server_port}/v1", "api_key": "local-synthetic-no-auth"},
                  "agent": {"max_turns": 3}, "terminal": {"backend": "local", "cwd": str(project)},
                  "plugins": {"enabled": []}, "memory": {"memory_enabled": False, "user_profile_enabled": False}}
        (home / "config.yaml").write_text(json.dumps(config))
        token, password = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        env = {k: os.environ[k] for k in ("PATH", "LANG", "TMPDIR") if k in os.environ}
        env.update(HOME=str(home), HERMES_HOME=str(home), HERMES_DASHBOARD_SESSION_TOKEN=token,
                   HERMES_DASHBOARD_BASIC_AUTH_USERNAME="direct-fixture", HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=password,
                   HERMES_DASHBOARD_BASIC_AUTH_SECRET=secrets.token_urlsafe(48), PYTHONUNBUFFERED="1", NO_PROXY="127.0.0.1,localhost")
        handoff = None
        process = subprocess.Popen([args.hermes, "serve", "--host", "127.0.0.1", "--port", str(port), "--isolated", "--skip-build"],
                                   cwd=project, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            origin = f"http://127.0.0.1:{port}"
            deadline = time.monotonic() + 45
            while True:
                if process.poll() is not None:
                    raise RuntimeError("Stock host exited")
                try:
                    if request_status(origin, token)[0] == 200:
                        break
                except OSError:
                    pass
                if time.monotonic() > deadline:
                    raise TimeoutError("Host readiness")
                time.sleep(0.2)
            _, _, session_tokens = exercise_http(origin, "direct-fixture", password)
            handoff = PrivateProbeConfiguration(temp, {"address": origin, "username": "direct-fixture",
                "password": password, "token": session_tokens["access_token"], "isolated_fixture": "true"})
            secret_config = handoff.__enter__()
            client_env = {k: os.environ[k] for k in ("PATH", "LANG", "TMPDIR") if k in os.environ}
            client_env["DIRECT_PROBE_CONFIG"] = str(secret_config)
            if args.ios_tests:
                args.result_root.mkdir(parents=True, exist_ok=False)
                client_env["TEST_RUNNER_DIRECT_PROBE_CONFIG"] = str(secret_config)
                command = ["xcodebuildmcp", "simulator", "test", "--project-path", str(repo / "Bighelp.xcodeproj"),
                    "--scheme", "Bighelp", "--configuration", "Debug", "--simulator-id", args.simulator_id,
                    "--derived-data-path", str(args.derived_data), "--prefer-xcodebuild", "--output", "json",
                    "--json", json.dumps({"extraArgs": ["-parallel-testing-enabled", "NO"] + [
                        "-only-testing:" + selection for selection in (args.only_testing or [
                            "BighelpTests/DirectHermesLiveTests", "BighelpTests/DirectHermesEndpointTests",
                            "BighelpTests/DirectHermesConversationTests", "BighelpUITests/DirectHermesUITests"])],
                        "testRunnerEnv": {"DIRECT_PROBE_CONFIG": str(secret_config)}, "progress": False})]
                with (args.result_root / "xcodebuild.log").open("w") as log:
                    result = subprocess.run(command, env=client_env, cwd=repo, stdout=log, stderr=subprocess.STDOUT, timeout=480)
                print(json.dumps({"exit_code": result.returncode, "result_root": str(args.result_root)}))
                result.check_returncode()
            else:
                subprocess.run([str(executable)], env=client_env, check=True, timeout=100)
        finally:
            if handoff is not None: handoff.__exit__()
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            model.shutdown()
            model.server_close()


if __name__ == "__main__":
    main()
