from __future__ import annotations

import unittest

from loopdy_plugin.hooks import normalize_hook
from loopdy_plugin.workspace_control import _event_projection


class HomeWorkCompletionTests(unittest.TestCase):
    def test_user_completion_retains_identity_without_copying_reply(self):
        event = normalize_hook(
            "on_session_end", profile="default", platform="loopdy",
            session_id="chat-work", turn_id="turn-work", completed=True,
            failed=False, assistant_response="PRIVATE REPLY MUST NOT LEAK",
        )
        self.assertIsNotNone(event, "Home needs a durable completed user-turn record")
        self.assertEqual(event.type, "session.completed")
        self.assertEqual(event.session_id, "chat-work")
        self.assertNotIn("PRIVATE REPLY", repr(event.detail))

    def test_registered_completion_persists_refreshes_and_pushes_with_cron(self):
        import json
        import sqlite3
        import tempfile
        import uuid
        from pathlib import Path
        from types import SimpleNamespace
        from unittest.mock import patch
        from loopdy_plugin.activity_bridge import LinkActivityBroker
        from loopdy_plugin.managed_notifications import ManagedNotifications
        from loopdy_plugin.registration import register
        from loopdy_plugin.store import LoopdyStore
        if __package__:
            from .test_registration import _Context, _Service
        else:
            from test_registration import _Context, _Service

        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            store = LoopdyStore(directory / "events.sqlite3")
            service, context = _Service(), _Context()
            service.store = store
            now = 1_800_000_000
            grant_id = str(uuid.uuid4())
            requests = []
            grant = {}

            def transport(method, path, raw, headers):
                requests.append((method, path, raw, headers))
                if path.endswith("/events"):
                    return {"version": 1, "status": "accepted", "deliveryId": "fixture-delivery"}
                return {"version": 1, "grant": grant}

            sessions = SimpleNamespace(
                get_session=lambda session_id: {
                    "id": session_id, "profile_name": "personal",
                }
            )
            presentation = patch.object(
                ManagedNotifications,
                "_agent_presentation",
                return_value=(
                    "Fixture Agent",
                    {
                        "mimeType": "image/png",
                        "sha256": "a" * 64,
                        "data": "data:image/png;base64,ZmFrZQ==",
                    },
                ),
            )
            presentation.start()
            self.addCleanup(presentation.stop)
            managed = ManagedNotifications(
                directory / "managed", transport=transport, clock=lambda: now,
                session_opener=lambda profile, read, read_only: read(sessions),
            )
            grant.update({
                "grantId": grant_id,
                "hostKeyId": managed.key_id,
                "hostPublicKey": managed.public_key,
                "authorizationEpoch": 1,
                "profile": "personal",
                "eventTypes": ["session.completed", "scheduled.completed"],
                "createdAt": now - 10,
                "expiresAt": now + 3600,
                "revision": 1,
                "provider": "buzzkit",
                "subscriberScope": "account",
                "state": "active",
            })
            managed.enroll(grant_id, str(uuid.uuid4()))
            managed.subscribe(grant_id, "personal", "stored-work", True)
            cron_session = "cron_fixture_20260906_120000"
            managed.subscribe(grant_id, "personal", cron_session, True)
            requests.clear()

            class RecordingBroker(LinkActivityBroker):
                def __init__(self):
                    super().__init__()
                    self.notifications = []

                def publish(self, value):
                    if value.get("type") == "notification.event":
                        self.notifications.append(value)
                        self.assert_durable(value["eventId"])
                    return True

                def assert_durable(self, event_id):
                    if not store.get_event(event_id):
                        raise AssertionError("Refresh arrived before durable completion")

            broker = RecordingBroker()
            broker.bind_link_session("stored-work", "visible-work")
            load_producer = managed.producer_loaded
            with (
                patch("loopdy_plugin.managed_notifications.get_managed_notifications", return_value=managed),
                patch.object(
                    managed,
                    "producer_loaded",
                    side_effect=lambda profile, **kwargs: load_producer(
                        profile, start_worker=False, **kwargs
                    ),
                ),
            ):
                register(context, service=service, activity_broker=broker)

            reply = dict(
                platform="desktop", session_id="stored-work", turn_id="turn-work",
                profile_name="personal", assistant_response="Ordinary desktop reply",
            )
            context.hooks["post_llm_call"](**reply)
            completion = dict(
                platform="desktop", session_id="stored-work", turn_id="turn-work",
                profile_name="personal", completed=True, failed=False, interrupted=False,
            )
            context.hooks["on_session_end"](**completion)
            context.hooks["on_session_end"](**completion)

            reopened = LoopdyStore(directory / "events.sqlite3")
            rows = [row for row in reopened.list_events() if row["type"] == "session.completed"]
            self.assertEqual(len(rows), 1, "Repeated observer delivery must not duplicate a run")
            self.assertEqual(rows[0]["profile"], "personal")
            self.assertIn(rows[0]["session_id"], {"stored-work", "visible-work"})
            self.assertEqual(_event_projection(rows[0])["type"], "session.completed")
            self.assertEqual(len(broker.notifications), 1, "A committed new completion needs one encrypted refresh signal")
            self.assertEqual(broker.notifications[0]["eventType"], "session.completed")
            self.assertNotIn("sessionId", broker.notifications[0])
            self.assertFalse(any(getattr(event, "type", None) == "session.completed"
                                 for event, _ in service.events), "Home records must not add push notifications")
            with sqlite3.connect(managed.db_path) as db:
                self.assertEqual(db.execute("SELECT COUNT(*) FROM events").fetchone()[0], 1)
                self.assertEqual(db.execute("SELECT COUNT(*) FROM pending").fetchone()[0], 1)
            self.assertEqual(requests, [])

            context.hooks["post_llm_call"](
                platform="cron", session_id=cron_session, turn_id="turn-cron",
                profile_name="personal", assistant_response="Scheduled result",
            )
            context.hooks["on_session_end"](
                platform="cron", session_id=cron_session, turn_id="turn-cron",
                profile_name="personal", completed=True, failed=False, interrupted=False,
            )
            managed.drain_pending()
            pushes = [json.loads(raw) for method, path, raw, _ in requests
                      if method == "POST" and path.endswith("/events")]
            self.assertEqual(len(pushes), 2)
            by_type = {push["eventType"]: push for push in pushes}
            self.assertEqual(by_type["session.completed"]["content"]["text"], "Ordinary desktop reply")
            self.assertEqual(by_type["scheduled.completed"]["content"]["text"], "Scheduled result")
            unload = context.unload
            assert unload is not None
            unload()

    def test_stop_recovers_purpose_from_its_exact_durable_start(self):
        import tempfile
        from pathlib import Path
        from loopdy_plugin.activity_bridge import LinkActivityBroker
        from loopdy_plugin.registration import register
        from loopdy_plugin.store import LoopdyStore
        if __package__:
            from .test_registration import _Context, _Service
        else:
            from test_registration import _Context, _Service

        with tempfile.TemporaryDirectory() as directory:
            service, context = _Service(), _Context()
            service.store = LoopdyStore(Path(directory) / "events.sqlite3")
            service.enqueue = lambda event, target: service.store.record_event(event, target=target)
            register(context, service=service, activity_broker=LinkActivityBroker())
            context.hooks["subagent_start"](parent_session_id="parent-work", child_session_id="child-work",
                child_subagent_id="worker-id", child_goal="Review accessibility\nPRIVATE EXTRA BRIEF")
            context.hooks["subagent_stop"](parent_session_id="parent-work", child_session_id="child-work",
                child_status="completed", child_summary="PRIVATE COMPLETE REPLY")
            rows = [row for row in service.store.list_events() if row["type"] == "delegation.completed"]
            self.assertEqual(len(rows), 1)
            wire = _event_projection(rows[0])
            self.assertEqual(wire["detail"]["title"], "Review accessibility")
            self.assertEqual(wire["detail"]["child_session_id"], "child-work")
            self.assertEqual(wire["detail"]["delegation_id"], "worker-id")
            self.assertNotIn("PRIVATE", repr(wire))

    def test_cron_runs_keep_distinct_identity_and_normalized_failure_is_not_success(self):
        first = normalize_hook("on_session_end", profile="default", platform="cron",
            session_id="cron_job-one_20260906_120000", completed=True)
        second = normalize_hook("on_session_end", profile="default", platform="cron",
            session_id="cron_job-one_20260906_130000", completed=True)
        self.assertNotEqual(first.event_id, second.event_id)
        self.assertEqual(first.job_id, second.job_id)
        for fields in [dict(completed=False), dict(completed=True, interrupted=True),
                       dict(completed=True, failed=True), dict(completed=True, platform="subagent")]:
            payload = dict(platform="loopdy", session_id="work", turn_id="turn") | fields
            event = normalize_hook("on_session_end", profile="default", **payload)
            self.assertTrue(event is None or event.type != "session.completed")

    def test_child_completion_keeps_purpose_and_child_coordinate_on_wire(self):
        event = normalize_hook(
            "subagent_stop", profile="default", parent_session_id="parent-work",
            child_session_id="child-work", child_subagent_id="child-agent",
            child_status="completed", child_role="leaf",
            child_goal="Review the Home activity transitions",
            child_summary="The transitions are correct.",
        )
        self.assertEqual(event.type, "delegation.completed")
        row = {
            "event_id": event.event_id, "type": event.type,
            "profile": event.profile, "session_id": event.session_id,
            "detail": event.detail, "created_at": 1_800_000_000,
        }
        projected = _event_projection(row)
        self.assertEqual(projected["detail"].get("child_session_id"), "child-work")
        self.assertEqual(projected["detail"].get("title"), "Review the Home activity transitions")
        self.assertNotEqual(projected["detail"]["title"], "leaf")


if __name__ == "__main__":
    unittest.main()
