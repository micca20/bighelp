"""Exercise Workspace mutation DTOs against an explicit official Hermes checkout.

Run with that checkout's compatible Python environment. All writes belong to a
temporary Hermes home; no server, gateway, provider or production session runs.
"""

import argparse
import asyncio
import os
from pathlib import Path
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from unittest.mock import patch


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--hermes-root", type=Path, required=True)
    args = parser.parse_args()
    source = args.hermes_root.resolve(strict=True)
    if not (source / "tui_gateway" / "server.py").is_file():
        parser.error("Choose an official Hermes source checkout.")

    with tempfile.TemporaryDirectory(prefix="loopdy-workspace-contract-") as temporary:
        home = Path(temporary)
        os.environ["HERMES_HOME"] = str(home)
        sys.dont_write_bytecode = True
        sys.path.insert(0, str(source))
        from tui_gateway.server import handle_request

        class WorkspaceNativeContracts(unittest.TestCase):
            def request(self, method, params):
                response = handle_request({
                    "jsonrpc": "2.0", "id": "workspace-contract",
                    "method": method, "params": params,
                })
                self.assertIsInstance(response, dict)
                self.assertEqual(response["id"], "workspace-contract")
                self.assertNotIn("error", response)
                return response["result"]

            def test_project_partial_rename_and_reversible_archive(self):
                folder = home / "sample-project"
                folder.mkdir()
                result = self.request("projects.create", {
                    "name": "Synthetic project", "folders": [str(folder)],
                    "description": "Preserve this description",
                })
                project = result["project"]
                updated = self.request("projects.update", {
                    "id": project["id"], "name": "Renamed synthetic project",
                })["project"]
                self.assertEqual(updated["id"], project["id"])
                self.assertEqual(updated["name"], "Renamed synthetic project")
                self.assertEqual(updated["description"], "Preserve this description")
                archived = self.request("projects.archive", {"id": project["id"], "restore": False})
                self.assertTrue(next(p for p in archived["projects"] if p["id"] == project["id"])["archived"])
                self.assertTrue(folder.exists())
                restored = self.request("projects.archive", {"id": project["id"], "restore": True})
                self.assertFalse(next(p for p in restored["projects"] if p["id"] == project["id"])["archived"])
                self.assertTrue(folder.exists())

            def test_reasoning_default_receipt_and_readback(self):
                for effort in ("none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"):
                    with self.subTest(effort=effort):
                        result = self.request("config.set", {
                            "key": "reasoning", "value": effort, "scope": "global",
                        })
                        self.assertEqual(result, {"key": "reasoning", "value": effort})
                        readback = self.request("config.get", {"key": "reasoning"})
                        self.assertEqual(readback["value"], effort)
                        self.assertIn(readback["display"], ("show", "hide"))
                self.assertTrue((home / "config.yaml").is_file())

            def test_unknown_profile_never_falls_back(self):
                # The in-process dispatcher raises; the native WS boundary
                # translates this failure into its wire error envelope.
                with self.assertRaises(FileNotFoundError):
                    handle_request({
                        "jsonrpc": "2.0", "id": "unknown-profile",
                        "method": "projects.list", "params": {"profile": "missing-loopdy-test-profile"},
                    })

            def test_stored_session_move_and_project_association(self):
                from hermes_state import SessionDB
                from hermes_cli.web_routers.sessions import get_session_detail
                old = home / "session-source"
                destination = home / "session-destination"
                old.mkdir()
                destination.mkdir()
                with SessionDB(home / "state.db") as db:
                    db.create_session("native-project-fixture", source="cli", cwd=str(old))
                    self.assertEqual(db.get_session("native-project-fixture")["cwd"], str(old))
                project = self.request("projects.create", {
                    "profile": "default", "name": "Session destination", "folders": [str(destination)],
                })["project"]
                moved = self.request("session.workspace.move", {
                    "profile": "default", "session_key": "native-project-fixture", "cwd": str(destination),
                })
                self.assertEqual(moved["cwd"], str(destination))
                detail = asyncio.run(get_session_detail("native-project-fixture", profile="default"))
                self.assertEqual(detail["id"], "native-project-fixture")
                self.assertEqual(detail["profile"], "default")
                self.assertEqual(detail["cwd"], str(destination))
                association = self.request("projects.for_cwd", {"profile": "default", "cwd": str(destination)})
                self.assertEqual(association["project"]["id"], project["id"])

            def cron_modules(self):
                from cron.scheduler_provider import InProcessCronScheduler, resolve_cron_scheduler
                from hermes_cli.web_routers import cron
                from hermes_cli.web_server_cron import _cron_profile_home, _cron_store_scope
                from hermes_cli.web_models import CronJobCreate, CronJobUpdate
                self.assertEqual(_cron_profile_home("default")[1].resolve(), home.resolve())
                with _cron_store_scope(home):
                    self.assertIsInstance(resolve_cron_scheduler(), InProcessCronScheduler)
                return cron, CronJobCreate, CronJobUpdate

            def test_cron_crud_uses_real_profile_store_and_exact_rows(self):
                cron, Create, Update = self.cron_modules()
                created = cron._create_cron_job_sync(Create(
                    name="Synthetic schedule", prompt="Synthetic prompt",
                    schedule="0 8 * * *", deliver="local",
                ), "default")
                self.assertEqual(created["profile"], "default")
                self.assertEqual(created["schedule"]["expr"], "0 8 * * *")
                updated = cron._update_cron_job_sync(created["id"], Update(updates={
                    "name": "Renamed schedule", "prompt": "Updated synthetic prompt",
                    "schedule": "0 9 * * *", "deliver": "local",
                }), "default")
                self.assertEqual(updated["id"], created["id"])
                self.assertEqual(updated["prompt"], "Updated synthetic prompt")
                paused = cron._pause_cron_job_sync(created["id"], "default")
                self.assertFalse(paused["enabled"])
                self.assertEqual(paused["state"], "paused")
                self.assertTrue(cron._resume_cron_job_sync(created["id"], "default")["enabled"])
                self.assertEqual(cron._delete_cron_job_sync(created["id"], "default"), {"ok": True})
                self.assertFalse(any(row["id"] == created["id"] for row in cron._list_cron_jobs_sync("default")))

            def test_cron_paused_trigger_passes_force_and_returns_resumed_state(self):
                cron, Create, _ = self.cron_modules()
                created = cron._create_cron_job_sync(Create(
                    name="Synthetic paused", prompt="Do not execute a model.",
                    schedule="every 1h", deliver="local", paused=True,
                ), "default")

                def fire(profile, job_id, *, force=False):
                    self.assertEqual(profile, "default")
                    self.assertEqual(job_id, created["id"])
                    self.assertTrue(force)
                    cron._resume_cron_job_sync(job_id, profile)
                    return True

                # Stub only execution. The real handler and native storage still
                # establish the wire semantics without running a provider/agent.
                with patch.object(cron, "_fire_cron_job_for_profile", side_effect=fire):
                    result = cron._trigger_cron_job_sync(created["id"], "default")
                self.assertTrue(result["enabled"])
                self.assertEqual(result["profile"], "default")

            def test_cron_exhausted_one_shot_returns_completed_not_paused(self):
                cron, Create, _ = self.cron_modules()
                future = (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()
                created = cron._create_cron_job_sync(Create(
                    name="Synthetic one-shot", prompt="Do not execute a model.",
                    schedule=future, deliver="local",
                ), "default")

                def fire(profile, job_id, *, force=False):
                    cron._delete_cron_job_sync(job_id, profile)
                    return True

                with patch.object(cron, "_fire_cron_job_for_profile", side_effect=fire):
                    result = cron._trigger_cron_job_sync(created["id"], "default")
                self.assertEqual(result["id"], created["id"])
                self.assertFalse(result["enabled"])
                self.assertEqual(result["state"], "completed")

        suite = unittest.defaultTestLoader.loadTestsFromTestCase(WorkspaceNativeContracts)
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
