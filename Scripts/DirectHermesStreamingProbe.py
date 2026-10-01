"""Real stock Hermes WebSocket streaming with an explicitly synthetic local model.

The model asks stock Hermes to run `pwd` in a temporary directory, then emits
three text chunks. This is protocol/integration evidence, not a real AI answer.
No production credentials/config, relay or external inference is used.
"""
from __future__ import annotations
import argparse
import asyncio
import json
import os
import re
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
import websockets
from DirectHermesProtocolProbe import request_status


class SyntheticModel(BaseHTTPRequestHandler):
    calls = 0
    reaction_notes = 0
    offered_tools: set[str] = set()
    observed_nonces: set[str] = set()
    observation_lock = threading.Lock()
    fixture_terminal_command = "pwd"
    def log_message(self, format: str, *args: Any) -> None:
        pass
    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        tools = request.get("tools", [])
        SyntheticModel.offered_tools.update(t.get("function", {}).get("name", "") for t in tools)
        main = any(t.get("function", {}).get("name") == "terminal" for t in tools)
        has_tool = any(m.get("role") == "tool" for m in request.get("messages", []))
        latest_user = next((str(m.get("content", "")) for m in reversed(request.get("messages", [])) if m.get("role") == "user"), "")
        # A reaction note: the fixture agent chooses not to answer.
        reaction_note = "[The user reacted" in latest_user
        # "react direct": the fixture agent tapbacks the latest human message.
        # Plugins before 2.20.0 named the tool loopdy_react_to_message.
        react_names = ("react_to_message", "bighelp_react_to_message", "loopdy_react_to_message")
        react_tool = next((name for name in react_names
                           if any(t.get("function", {}).get("name") == name for t in tools)), None)
        # Hermes may list plugin tools only in the prompt's catalog, called through tool_call.
        catalog = " ".join(str(m.get("content", "")) for m in request.get("messages", []) if m.get("role") == "system")
        catalog_react = next((name for name in react_names[1:] if name in catalog), None)
        if catalog_react:
            SyntheticModel.offered_tools.add("catalog:" + catalog_react)
        bridged_react = react_tool is None and catalog_react is not None and any(
            t.get("function", {}).get("name") == "tool_call" for t in tools)
        if bridged_react:
            react_tool = "tool_call"
        wants_reaction = "react direct" in latest_user.lower() and react_tool is not None and not has_tool
        use_tool = main and not has_tool and not reaction_note
        second = "second direct" in latest_user.lower()
        hold = "hold direct" in latest_user.lower()
        # Long enough to leave the app mid-reply and have the turn finish while away.
        slow = "slow direct" in latest_user.lower()
        final_text = "Second direct fixture complete." if second else "Direct streaming fixture complete."
        nonce = re.search(r"\bNATIVE_PROBE_[a-f0-9]{32}\b", latest_user)
        if nonce:
            with SyntheticModel.observation_lock:
                SyntheticModel.observed_nonces.add(nonce.group(0))
            final_text += " " + nonce.group(0)
        SyntheticModel.calls += 1
        if reaction_note:
            SyntheticModel.reaction_notes += 1
            final_text = "[SILENT]"
        react_arguments = ({"name": catalog_react, "arguments": {"emoji": "👍"}}
                           if bridged_react else {"emoji": "👍"})
        tool_call = ({"id": "call_direct_fixture_react", "type": "function",
                      "function": {"name": react_tool, "arguments": json.dumps(react_arguments)}}
                     if wants_reaction else
                     {"id": "call_direct_fixture_pwd", "type": "function",
                      "function": {"name": "terminal", "arguments": json.dumps({"command": self.fixture_terminal_command})}})
        use_tool = use_tool or wants_reaction
        message: dict[str, Any] = ({"role": "assistant", "content": None, "tool_calls": [tool_call]}
                                   if use_tool else {"role": "assistant", "content": final_text})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream" if request.get("stream") else "application/json")
        self.end_headers()
        if not request.get("stream"):
            self.wfile.write(json.dumps({"id": "fixture", "object": "chat.completion", "model": "fixture-model", "created": 1,
                "choices": [{"index": 0, "message": message, "finish_reason": "tool_calls" if use_tool else "stop"}],
                "usage": {"prompt_tokens": 10, "completion_tokens": 10, "total_tokens": 20}}).encode())
            return
        deltas = ([{"role": "assistant", "tool_calls": [{**message["tool_calls"][0], "index": 0}]}] if use_tool else
                  [{"role": "assistant", "content": "[SILENT]"}] if reaction_note else
                  [{"role": "assistant", "reasoning_content": "Checking the direct stream."},
                   {"content": "Second direct " if second else "Direct "}, {"content": "fixture " if second else "streaming fixture "},
                   {"content": "complete." + (" " + nonce.group(0) if nonce else "")}])
        for delta in deltas + [{}]:
            data = {"id": "fixture", "object": "chat.completion.chunk", "created": 1, "model": "fixture-model",
                    "choices": [{"index": 0, "delta": delta,
                                 "finish_reason": ("tool_calls" if use_tool else "stop") if not delta else None}]}
            self.wfile.write(("data: " + json.dumps(data) + "\n\n").encode())
            self.wfile.flush()
            if delta:
                time.sleep(5.0 if slow and "content" in delta else 1.0 if hold and "content" in delta else 0.04)
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


async def exercise(origin, token, project, output):
    events, pending = [], {}
    async with websockets.connect(origin.replace("http://", "ws://") + "/api/ws?token=" + token, max_size=8_000_000) as ws:
        ready = asyncio.Event()
        async def receive():
            async for raw in ws:
                for line in raw.splitlines():
                    if not line.strip():
                        continue
                    message = json.loads(line)
                    if message.get("method") == "event":
                        event = message["params"]
                        if event.get("type") == "gateway.ready":
                            ready.set()
                        else:
                            events.append({"received_at": time.monotonic(), "frame": message})
                    elif message.get("id") in pending:
                        pending.pop(message["id"]).set_result(message)
        receive_task = asyncio.create_task(receive())
        counter = 0
        async def rpc(method, params):
            nonlocal counter
            counter += 1
            future = asyncio.get_running_loop().create_future()
            pending[counter] = future
            await ws.send(json.dumps({"jsonrpc": "2.0", "id": counter, "method": method, "params": params}))
            result = await asyncio.wait_for(future, timeout=75)
            assert "error" not in result, f"{method} failed: {result.get('error', {}).get('code')}"
            return result["result"]
        try:
            await asyncio.wait_for(ready.wait(), timeout=20)
            created = await rpc("session.create", {"cwd": str(project), "source": "loopdy-direct-test"})
            sid = created["session_id"]
            prompt = await rpc("prompt.submit", {"session_id": sid, "text": "Run pwd once, then finish the direct streaming fixture."})
            deadline = time.monotonic() + 60
            while True:
                kinds = [entry["frame"]["params"].get("type") for entry in events]
                status = await rpc("session.status", {"session_id": sid})
                if "tool.complete" in kinds and "message.complete" in kinds and not status.get("running", False):
                    break
                if time.monotonic() >= deadline:
                    raise TimeoutError("Expected real tool and terminal stream did not complete: " + str(sorted(set(kinds))))
                await asyncio.sleep(0.05)
            history = await rpc("session.history", {"session_id": sid})
            kinds = [entry["frame"]["params"].get("type") for entry in events]
            assert "tool.start" in kinds and "tool.complete" in kinds
            assert "message.delta" in kinds and "message.complete" in kinds
            assert str(project) in json.dumps([e for e in events if e["frame"]["params"].get("type") == "tool.complete"]), "Real pwd result missing"
            result = {"source": "stock Hermes /api/ws + synthetic local model + real temporary-directory pwd",
                      "created": created, "prompt_result": prompt, "history": history, "events": events,
                      "event_types": sorted(set(kinds)), "model_calls": SyntheticModel.calls}
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(json.dumps(result, indent=2) + "\n")
            print(json.dumps({"outcome": "passed", "event_types": result["event_types"], "event_count": len(events),
                              "model_calls": SyntheticModel.calls, "receipt": str(output)}))
        finally:
            receive_task.cancel()
            try:
                await receive_task
            except asyncio.CancelledError:
                pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--hermes", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    model = ThreadingHTTPServer(("127.0.0.1", 0), SyntheticModel)
    threading.Thread(target=model.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="direct-stream-", dir="/tmp") as directory:
            home = Path(directory).resolve()
            project = home / "project"
            project.mkdir()
            config = {"model": {"default": "fixture-model", "provider": "custom",
                       "base_url": f"http://127.0.0.1:{model.server_port}/v1", "api_key": secrets.token_urlsafe(32)},
                      "agent": {"max_turns": 3}, "terminal": {"backend": "local", "cwd": str(project)},
                      "plugins": {"enabled": []}, "memory": {"memory_enabled": False, "user_profile_enabled": False}}
            (home / "config.yaml").write_text(json.dumps(config))
            token = secrets.token_urlsafe(32)
            with socket.socket() as reservation:
                reservation.bind(("127.0.0.1", 0))
                port = reservation.getsockname()[1]
            env = {k: os.environ[k] for k in ("PATH", "LANG", "TMPDIR") if k in os.environ}
            env.update(HOME=str(home), HERMES_HOME=str(home), HERMES_DASHBOARD_SESSION_TOKEN=token,
                       PYTHONUNBUFFERED="1", NO_PROXY="127.0.0.1,localhost")
            process = subprocess.Popen([args.hermes, "serve", "--host", "127.0.0.1", "--port", str(port), "--isolated", "--skip-build"],
                                       cwd=project, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                origin = f"http://127.0.0.1:{port}"
                deadline = time.monotonic() + 45
                while True:
                    if process.poll() is not None:
                        raise RuntimeError("Stock server exited before readiness")
                    try:
                        if request_status(origin, token)[0] == 200:
                            break
                    except OSError:
                        pass
                    if time.monotonic() > deadline:
                        raise TimeoutError("Server readiness")
                    time.sleep(0.2)
                asyncio.run(exercise(origin, token, project, args.output))
            finally:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
    finally:
        model.shutdown()
        model.server_close()


if __name__ == "__main__":
    main()
