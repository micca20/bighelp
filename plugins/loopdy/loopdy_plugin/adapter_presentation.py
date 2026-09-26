"""State-backed session presentation and exact-scope snapshots.

Operations use the calling LoopdyAdapter as their sole state/lifecycle owner.
Facade-owned callables and context variables are explicit call-time dependencies.
"""

from __future__ import annotations

import os
import time
from typing import Any
from .direct_runtime import runtime_owner
from .link_crypto import encode_base64url


def _start_session_presentation(self):
    """Gateway/account ownership, independent of either transport socket."""
    from .session_presentation import SessionPresentationStore
    from .session_stream import SessionStreamHub
    with self._presentation_lock:
        config = getattr(self.link_client, "config", None)
        owner = runtime_owner(config) if config is not None else None
        if self._session_presentation is not None and owner == self._presentation_owner:
            return
        if owner != self._presentation_owner:
            self._link_session_profiles.clear()
        self._close_session_presentation()
        self._presentation_owner = owner
        self._presentation_hub = SessionStreamHub()
        # Leave room for the canonical 128-KiB page and workspace envelope.
        self._session_presentation = SessionPresentationStore(
            self._presentation_hub, maximum_bytes=48_000)
        setter = getattr(self.activity_broker, "set_presentation_observer", None)
        if callable(setter):
            setter(self._capture_broker_presentation)


def _close_session_presentation(self):
    with self._presentation_lock:
        setter = getattr(self.activity_broker, "set_presentation_observer", None)
        if callable(setter):
            setter(None)
        if self._session_presentation is not None:
            assert self._presentation_hub is not None
            for agent_id, session_id in self._presentation_scopes:
                self._presentation_hub.reset(agent_id=agent_id, session_id=session_id)
            self._session_presentation.close()
        self._session_presentation = None
        self._presentation_scopes.clear()
        self._presentation_runs.clear()
        self._presentation_evicted = False


def _check_presentation_owner(self):
    config = getattr(self.link_client, "config", None)
    owner = runtime_owner(config) if config is not None else None
    if owner != self._presentation_owner:
        self._close_session_presentation()
        self._link_session_profiles.clear()
        raise ConnectionError("Session presentation account retired")
    if self._session_presentation is None:
        raise ConnectionError("Session presentation gateway retired")


def _presentation_scope(self, agent_id, session_id):
    import re
    # Reject normalization, contradictory bindings and unknown bare events.
    if (not isinstance(agent_id, str) or not agent_id
            or not re.fullmatch(r"[A-Za-z0-9_-]{1,96}", agent_id)
            or not isinstance(session_id, str) or not session_id
            or not re.fullmatch(r"[A-Za-z0-9_-]{1,180}", session_id)):
        raise ValueError("Session presentation scope is invalid")
    known = self._link_session_profiles.get(session_id)
    if known is not None and known != agent_id:
        raise ValueError("Session presentation profile contradicts binding")
    return agent_id, session_id


def _admit_presentation_scope(self, scope):
    assert self._session_presentation is not None and self._presentation_hub is not None
    record = self._presentation_scopes.get(scope)
    if record is None:
        if len(self._presentation_scopes) >= self._session_presentation.maximum_sessions:
            retired, _ = self._presentation_scopes.popitem(last=False)
            self._session_presentation.retire(agent_id=retired[0], session_id=retired[1])
            self._presentation_hub.reset(agent_id=retired[0], session_id=retired[1])
            self._presentation_runs.pop(retired, None)
            self._presentation_evicted = True
        record = {"cursor": 0, "incomplete": self._presentation_evicted}
        self._presentation_scopes[scope] = record
    self._presentation_scopes.move_to_end(scope)
    return record


def _capture_broker_presentation(self, payload):
    agent_id = payload.get("agentId")
    if agent_id is None:
        agent_id = self._link_session_profiles.get(payload.get("sessionId"))
    self._capture_session_presentation(agent_id, payload)


def _capture_session_presentation(self, agent_id, payload):
    with self._presentation_lock:
        self._check_presentation_owner()
        assert self._session_presentation is not None and self._presentation_hub is not None
        scope = self._presentation_scope(agent_id, payload.get("sessionId"))
        if payload.get("agentId", agent_id) != agent_id:
            raise ValueError("Session presentation profile mismatch")
        record = self._admit_presentation_scope(scope)
        try:
            self._session_presentation.publish(agent_id=agent_id, payload=payload)
            snapshot = self.session_presentation_snapshot(*scope)
            if not snapshot["complete"]:
                raise ValueError("Current session presentation is incomplete")
            return True
        except Exception:
            record["incomplete"] = True
            record["cursor"] = self._presentation_hub.reset(
                agent_id=scope[0], session_id=scope[1])
            raise


def session_presentation_snapshot(self, agent_id: str, session_id: str) -> dict[str, Any]:
    """Synchronous, detached live state for the exact authorized visible scope.

    Consumers bracket this read with canonical revision checks. They must
    reject incomplete snapshots, and use exact platform message IDs only
    when reconciling canonical rows with these presentation events.
    """
    from .link_contracts import _workspace_json
    with self._presentation_lock:
        self._check_presentation_owner()
        assert self._session_presentation is not None and self._presentation_hub is not None
        scope = self._presentation_scope(agent_id, session_id)
        snapshot = self._session_presentation.snapshot(agent_id=agent_id, session_id=session_id)
        record = self._presentation_scopes.get(scope)
        if record is not None:
            snapshot["coverageCursor"] = max(snapshot["coverageCursor"], record["cursor"])
            snapshot["complete"] = snapshot["complete"] and not record["incomplete"]
        elif self._presentation_evicted:
            snapshot["complete"] = False
        try:
            # Validate at the actual workspace nesting depth, not just the
            # event's standalone JSON size (cards may be more deeply nested).
            _workspace_json({"live": snapshot}, depth=0)
        except ValueError:
            record = self._admit_presentation_scope(scope)
            record["incomplete"] = True
            record["cursor"] = self._presentation_hub.reset(agent_id=agent_id, session_id=session_id)
            snapshot = {"coverageCursor": record["cursor"], "events": [], "complete": False}
        return snapshot


def _require_captured_draft(self, payload):
    if payload.get("type") != "assistant.message" or payload.get("delivery") != "draft":
        return
    snapshot = self.session_presentation_snapshot(payload.get("agentId"), payload.get("sessionId"))
    if not snapshot["complete"] or payload not in snapshot["events"]:
        # Link currently labels negotiated drafts as disposable. Do not
        # submit one unless this exact projection really is recoverable.
        raise ValueError("Draft has no complete state-backed presentation")


def _observe_presentation(self, event_name: str, coordinates: dict[str, Any], *, logger) -> bool:
    captured = False
    try:
        with self._presentation_lock:
            lease = coordinates.get("lease")
            if lease is not None:
                lease.route.check_current()
            if event_name == "assistant_message":
                captured = self._capture_session_presentation(
                    coordinates["profile"], coordinates["payload"])
            elif event_name == "processing_start":
                event = coordinates.get("event")
                source = getattr(event, "source", None)
                # Real Link and direct turns both carry registered leases;
                # legacy hooks require an explicit, verified source binding.
                agent_id = lease.profile if lease else getattr(source, "profile", None)
                session_id = lease.session_id if lease else getattr(source, "chat_id", None)
                if (lease is not None or (isinstance(session_id, str) and agent_id
                                         and self._link_session_profiles.get(session_id) == agent_id)):
                    self._check_presentation_owner()
                    assert self._session_presentation is not None and self._presentation_hub is not None
                    scope = self._presentation_scope(agent_id, session_id)
                    generation = lease.generation if lease else getattr(event, "message_id", None)
                    if not generation:
                        raise ValueError("Processing start has no exact run identity")
                    if self._presentation_runs.get(scope) != generation:
                        record = self._admit_presentation_scope(scope)
                        self._session_presentation.retire(agent_id=scope[0], session_id=scope[1])
                        record["cursor"] = self._presentation_hub.reset(agent_id=scope[0], session_id=scope[1])
                        record["incomplete"] = False
                        self._presentation_runs[scope] = generation
            elif event_name == "processing_complete" and lease is not None:
                scope = (lease.profile, lease.session_id)
                if self._presentation_runs.get(scope) == lease.generation:
                    self._presentation_runs.pop(scope, None)
                    # Hermes's processing-complete boundary follows its
                    # durable turn flush. Finals belong to canonical history,
                    # not an uncorrelated overlay retained until another turn.
                    if self._session_presentation is not None and self._presentation_hub is not None:
                        self._session_presentation.retire(agent_id=scope[0], session_id=scope[1])
                        record = self._admit_presentation_scope(scope)
                        record["cursor"] = self._presentation_hub.reset(agent_id=scope[0], session_id=scope[1])
                        record["incomplete"] = False
    except Exception:
        logger.warning("Loopdy session presentation update unavailable")
    voice = self._live_voice_runtime
    if voice is not None:
        try:
            voice.observe(event_name, **coordinates)
        except Exception:
            logger.warning("Loopdy live job observer unavailable")
    observer = self._presentation_observer
    if observer is not None:
        try:
            observer(event_name, **coordinates)
        except Exception:
            logger.warning("Loopdy presentation observer failed (%s)", event_name)
    return captured


async def _open_session_snapshot(self, runtime, context, agent_id, session_id):
    from .direct_server import DirectSessionView
    from .link_contracts import parse_workspace_request
    if self._session_presentation is None or runtime.hub is not self._presentation_hub:
        raise ValueError("session presentation unavailable")
    # Authenticated scope is authorized by the existing canonical state
    # operation, not by a caller-supplied stored/visible alias relationship.
    request = parse_workspace_request({"version": 1, "type": "workspace.request",
        "requestId": encode_base64url(os.urandom(18)), "operation": "sessions.state",
        "payload": {"agentId": agent_id, "storedId": session_id}, "sentAt": int(time.time())})
    feed = runtime.subscribe(agent_id=agent_id, session_id=session_id)
    cursor = feed.cursor
    try:
        state = await self.workspace_controller.execute(request)
        if state.get("agentId") != agent_id or state.get("sessionId") != session_id:
            raise ValueError("canonical session scope mismatch")
        live = state.pop("live", None)
        if not isinstance(live, dict) or live.get("complete") is not True:
            raise ValueError("complete session presentation unavailable")
        runtime.validate_peer(context.peer)
        return DirectSessionView({"state": state, "live": live}, feed,
                                 runtime.hub.process_epoch, cursor)
    except BaseException:
        feed.close()
        raise
