"""Real stock management and native observer proof in a disposable home.

Copies only the selected plugin candidate into a local Git fixture. Uses the
normal installer/scanner and real serve restart owned by this test. Native turn
is driven by an explicitly synthetic local model. No production host is changed.
"""
from __future__ import annotations
import argparse
import asyncio
import json
import os
from pathlib import Path
import secrets
import shutil
import sqlite3
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid
from http.server import ThreadingHTTPServer
import websockets
from DirectHermesStreamingProbe import SyntheticModel
from DirectHermesAuthenticationProbe import exercise_http


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--plugin",type=Path,required=True)
    parser.add_argument("--hermes",required=True)
    parser.add_argument("--output",type=Path,required=True)
    parser.add_argument("--preinstalled-fixture",action="store_true",help="Test an explicitly preprovisioned local development plugin; does not verify installer acceptance")
    parser.add_argument("--approval-fixture",action="store_true",help="Ask for a harmless guarded command and deny the exact native request; no command is approved")
    args=parser.parse_args()
    if args.approval_fixture:
        SyntheticModel.fixture_terminal_command = "chmod 777 fixture-permissions.txt"
    with tempfile.TemporaryDirectory(prefix="loopdy-stock-install-",dir="/tmp") as temporary:
        root=Path(temporary).resolve(); candidate=root/"candidate"; candidate.mkdir()
        files=subprocess.check_output(["git","ls-files","-co","--exclude-standard","-z"],cwd=args.plugin).split(b"\0")
        for encoded in set(files):
            if not encoded: continue
            relative=Path(os.fsdecode(encoded))
            if relative.parts[0].startswith(".") or "__pycache__" in relative.parts: continue
            source=args.plugin/relative
            if source.is_file() and not source.is_symlink():
                destination=candidate/relative; destination.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(source,destination)
        def git(*argv):
            return subprocess.check_output(["git",*argv],cwd=candidate,stderr=subprocess.DEVNULL,text=True).strip()
        git("init","-q");git("config","user.name","Bighelp integration fixture");git("config","user.email","fixture@example.invalid")
        git("add",".");git("commit","-qm","Fixture candidate");sha=git("rev-parse","HEAD")
        home=root/"home"; home.mkdir(); project=root/"project";project.mkdir()
        permission_fixture=project/"fixture-permissions.txt"
        permission_fixture.write_text("fixture only")
        permission_fixture.chmod(0o600)
        model=ThreadingHTTPServer(("127.0.0.1",0),SyntheticModel)
        threading.Thread(target=model.serve_forever,daemon=True).start()
        password=secrets.token_urlsafe(32)
        config={"dashboard":{"public_url":"http://fixture.invalid"},"model":{"provider":"custom","default":"fixture-model","base_url":f"http://127.0.0.1:{model.server_port}/v1","api_key":secrets.token_urlsafe(32)},
            "terminal":{"backend":"local","cwd":str(project)},"plugins":{"enabled":[]},"approvals":{"mode":"manual","timeout":30},"agent":{"max_turns":3},"memory":{"memory_enabled":False,"user_profile_enabled":False}}
        if args.preinstalled_fixture:
            shutil.copytree(candidate, home/"plugins/loopdy", ignore=shutil.ignore_patterns(".git"))
            config["plugins"]["enabled"]=["loopdy"]
        (home/"config.yaml").write_text(json.dumps(config))
        env={k:os.environ[k] for k in ("PATH","LANG","TMPDIR") if k in os.environ}
        env.update(HOME=str(home),HERMES_HOME=str(home),HERMES_DASHBOARD_BASIC_AUTH_USERNAME="fixture",HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=password,
            HERMES_DASHBOARD_BASIC_AUTH_SECRET=secrets.token_urlsafe(48),HERMES_DASHBOARD_SESSION_TOKEN=secrets.token_urlsafe(32),
            PYTHONDONTWRITEBYTECODE="1",NO_PROXY="127.0.0.1,localhost",HTTPS_PROXY="http://127.0.0.1:1",HTTP_PROXY="http://127.0.0.1:1")
        process=None; log=(root/"host.log").open("wb")
        def start():
            nonlocal process
            # Port 0 is supported; readiness URL is not printed because log can contain URLs.
            import socket
            with socket.socket() as s: s.bind(("127.0.0.1",0));port=s.getsockname()[1]
            origin=f"http://127.0.0.1:{port}"
            process=subprocess.Popen([args.hermes,"serve","--isolated","--skip-build","--host","127.0.0.1","--port",str(port)],env=env,cwd=project,stdout=log,stderr=log)
            deadline=time.monotonic()+45
            while time.monotonic()<deadline:
                if process.poll() is not None: raise RuntimeError("fixture host exited")
                try:
                    with urllib.request.urlopen(origin+"/api/health",timeout=1) as response:
                        if response.status==200:return origin
                except (OSError,urllib.error.URLError): pass
                time.sleep(.1)
            raise RuntimeError("fixture host startup timeout")
        def stop():
            nonlocal process
            if process and process.poll() is None:
                process.terminate()
                try:process.wait(timeout=20)
                except subprocess.TimeoutExpired:process.kill();process.wait(timeout=5)
            process=None
        def fetch(origin,path,token=None,body=None):
            headers={"content-type":"application/json"}
            if token:headers["Authorization"]="Bearer "+token
            request=urllib.request.Request(origin+path,headers=headers,data=json.dumps(body).encode() if body is not None else None)
            try:response=urllib.request.urlopen(request,timeout=90)
            except urllib.error.HTTPError as error:response=error
            with response:
                try:value=json.load(response)
                except ValueError:value={}
                return response.status,value
        try:
            origin=start();_,_,tokens=exercise_http(origin,"fixture",password);token=tokens["access_token"]
            path="/api/dashboard/agent-plugins/install"
            payload={"identifier":candidate.as_uri(),"ref":sha,"catalog_name":None,"enable":True,"force":False}
            assert fetch(origin,path,body=payload)[0]==401
            before=None
            if not args.preinstalled_fixture:
                status,installed=fetch(origin,path,token,payload)
                if status!=200 or installed.get("ok") is not True:
                    print(json.dumps({"outcome":"blocked","stage":"normal-scanned-install","http":status,"detail":str(installed.get("detail", ""))[:250]}))
                    raise RuntimeError("candidate installer rejected")
                metadata=json.loads((home/"plugins/.install-metadata.json").read_text())
                assert sha in json.dumps(metadata)
                before=fetch(origin,"/api/plugins/loopdy/notifications/capabilities",token)[0]
                assert before==404,"Fresh routes must not be claimed active in the old backend process"
                stop();origin=start();_,_,tokens=exercise_http(origin,"fixture",password);token=tokens["access_token"]
            status,capability=fetch(origin,"/api/plugins/loopdy/notifications/capabilities",token)
            if status != 200 or capability.get("producerCapabilities", {}).get("sessionCompletion") is not True:
                print(json.dumps({"stage":"pre-turn-capability","http":status,"producers":capability.get("producerCapabilities"),"keys":sorted(capability)}))
            assert status==200, "Native process did not mount candidate API"
            async def native_turn():
                status,ticket=fetch(origin,"/api/auth/ws-ticket",token,{})
                assert status==200
                async with websockets.connect(origin.replace("http:","ws:")+"/api/ws",subprotocols=["hermes-gateway-v1","hermes-gateway-ticket."+ticket["ticket"]],max_size=8_000_000) as ws:
                    received_events = []
                    async def rpc(method,params,request_id):
                        await ws.send(json.dumps({"jsonrpc":"2.0","id":request_id,"method":method,"params":params}))
                        while True:
                            for line in (await asyncio.wait_for(ws.recv(),timeout=30)).splitlines():
                                msg=json.loads(line)
                                if msg.get("method") == "event": received_events.append(msg["params"])
                                if msg.get("id")==request_id:
                                    assert "error" not in msg,(method,msg.get("error",{}).get("code"))
                                    return msg["result"]
                    installed_list=await rpc("plugins.manage",{"action":"list"},1)
                    assert any(x.get("name")=="loopdy" and (args.preinstalled_fixture or x.get("pinned_sha")==sha) for x in installed_list["plugins"])
                    _, after_list = fetch(origin,"/api/plugins/loopdy/notifications/capabilities",token)
                    print(json.dumps({"stage":"after-plugin-list","producers":after_list.get("producerCapabilities")}))
                    created=await rpc("session.create",{"profile":"default","source":"desktop","cwd":str(project)},2)
                    sid=created["session_id"];stored=created["stored_session_id"]
                    # Pre-authorized synthetic subscription isolates the real native
                    # observer. Cloud enrollment is tested separately, not fabricated here.
                    journal=home/"plugin-data/loopdy/managed-notifications/journal.sqlite3"
                    grant_id=str(uuid.uuid4());now=int(time.time())
                    grant=dict(grantId=grant_id,hostKeyId=capability["hostKeyId"],hostPublicKey=capability["hostPublicKey"],deviceId="fixture-phone",
                        recipientPublicKey=capability["hostPublicKey"],recipientKeyId=capability["hostKeyId"],recipientRevision=1,authorizationEpoch=1,
                        profile="default",eventTypes=["session.completed","session.failed"]+(["approval.required"] if args.approval_fixture else []),createdAt=now-1,expiresAt=now+3600,revision=1,tenantId="fixture-tenant",state="active")
                    import hashlib,base64
                    reference=base64.urlsafe_b64encode(hashlib.sha256(("default\0"+stored).encode()).digest()).rstrip(b"=").decode()
                    with sqlite3.connect(journal) as db:
                        db.execute("INSERT INTO grants VALUES(?,?,'active',?)",(grant_id,json.dumps(grant),now+3600))
                        db.execute("INSERT INTO subscriptions VALUES(?,?,?,?)",(grant_id,"default",stored,reference))
                    await rpc("prompt.submit",{"session_id":sid,"text":"Run pwd once, then finish the direct streaming fixture."},3)
                    deadline=time.monotonic()+45
                    denied_request = None
                    approval_detail = None
                    probe_id = 100
                    while time.monotonic()<deadline:
                        if args.approval_fixture:
                            probe_id += 1
                            last_status = await rpc("session.status", {"session_id":sid}, probe_id)
                            prompts = [e for e in received_events if e.get("type")=="approval.request" and e.get("session_id")==sid]
                            if prompts and denied_request is None:
                                request_id = prompts[-1]["payload"].get("request_id")
                                assert isinstance(request_id,str) and request_id
                                with sqlite3.connect(journal) as db:
                                    observed=db.execute("SELECT e.detail_json,a.state FROM events e JOIN approval_attention a ON a.event_id=e.event_id WHERE e.grant_id=?",(grant_id,)).fetchone()
                                assert observed and observed[1]=="pending", "native approval did not reach managed observer"
                                approval_detail=json.loads(observed[0])
                                assert approval_detail["eventType"]=="approval.required" and approval_detail["sessionId"]==stored
                                assert "requestId" not in approval_detail
                                probe_id += 1
                                response=await rpc("approval.respond",{"session_id":sid,"request_id":request_id,"choice":"deny","all":False},probe_id)
                                assert response.get("resolved"), "exact fixture denial was not accepted"
                                denied_request = request_id
                        with sqlite3.connect(journal) as db:
                            event=db.execute("SELECT detail_json FROM events WHERE grant_id=? AND json_extract(detail_json,'$.eventType')='session.completed'",(grant_id,)).fetchone()
                        if event:
                            detail=json.loads(event[0]);assert detail["sessionId"]==stored and detail["eventType"]=="session.completed"
                            extra = {}
                            if args.approval_fixture:
                                assert denied_request and approval_detail
                                assert permission_fixture.stat().st_mode & 0o777 == 0o600, "denied command was executed"
                                with sqlite3.connect(journal) as db:
                                    retirement=db.execute("SELECT state FROM approval_attention WHERE event_id=?",(approval_detail["eventId"],)).fetchone()
                                assert retirement and retirement[0]=="retired"
                                extra={"nativeApprovalObserved":True,"nativeExactRequestDenied":True,"approvalRetiredAfterResponse":True}
                            return {"nativeCompletionObserved":True,"exactStoredSession":True,"eventNamespacesGrant":detail["eventId"].startswith(grant_id+":"),**extra}
                        await asyncio.sleep(.1)
                    with sqlite3.connect(journal) as db:
                        event_types = [row[0] for row in db.execute("SELECT json_extract(detail_json,'$.eventType') FROM events WHERE grant_id=?",(grant_id,))]
                    diagnostics={"outcome":"failed","stage":"native-observer", "eventTypes":sorted({e.get("type", "") for e in received_events}),"journalEventTypes":event_types,
                        "nativeApprovalSeen":any(e.get("type")=="approval.request" for e in received_events),"nativeRequestDenied":denied_request is not None,
                        "modelCalls":SyntheticModel.calls,"status":last_status if args.approval_fixture else None,
                        "errors":[e.get("payload") for e in received_events if e.get("type") in ("error","tool.complete","turn.failed")]}
                    args.output.write_text(json.dumps(diagnostics,indent=2)+"\n")
                    print(json.dumps(diagnostics))
                    raise RuntimeError("No real native completion reached managed journal")
            result=asyncio.run(native_turn())
            receipt={"outcome":"passed","normalScannerInstall":not args.preinstalled_fixture,"preinstalledDevelopmentFixture":args.preinstalled_fixture,"exactPinReadback":not args.preinstalled_fixture,"beforeRestartHTTP":before,"afterRestartHTTP":status,
                "producerLoadedInNativeProcess":True,"scope":"disposable stock host; synthetic local model; pre-authorized test subscription; all external network blocked",**result}
            args.output.write_text(json.dumps(receipt,indent=2)+"\n");print(json.dumps(receipt))
        finally:
            stop();model.shutdown();model.server_close();log.close()
            shutil.copy2(root/"host.log", args.output.with_suffix(".host.log"))

if __name__=="__main__": main()
