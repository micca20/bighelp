"""Paired transport operations with exact request/reply ownership.

Operations use the calling LoopdyAdapter as their sole state/lifecycle owner.
Facade-owned callables and context variables are explicit call-time dependencies.
"""

from __future__ import annotations

import asyncio
from typing import Any, Callable
from .inbound_dispatch import (
    AuthenticatedRequestOwner,
    ReplyRoute,
    DirectResponseCapture,
    AttachmentUnavailable,
    parse_authenticated_payload,
    current_reply_route,
)
from .direct_runtime import runtime_owner
from .link_client import InboundLinkTurn
from .link_contracts import DIRECTED_FRAMES_CAPABILITY, STATE_BACKED_PRESENTATION_CAPABILITY


async def _start_direct(self, *, get_hermes_home) -> bool:
    runtime = None
    try:
        settings = (self._direct_settings_getter() if self._direct_settings_getter
                    else self.direct_settings)
        if not settings.enabled:
            return False
        client = self.link_client
        config = self._direct_current_config()
        if config is None or client is None:
            raise ValueError("Direct requires an existing Link pairing")
        with self._presentation_lock:
            self._check_presentation_owner()
            if runtime_owner(config) != self._presentation_owner:
                self._close_session_presentation()
                raise ValueError("Direct pairing contradicts presentation owner")
            hub = self._presentation_hub
        runtime = self._direct_runtime_factory(
            settings=settings, config=config,
            state=self._link_state or client.state,
            journal_path=get_hermes_home() / "plugin-data" / "loopdy" / "direct-commands.sqlite3",
            dispatch=self.dispatch_direct, open_session=self.open_direct_session,
            config_getter=self._direct_current_config,
            settings_getter=self._direct_settings_getter,
            status_callback=self._on_direct_status, hub=hub)
        self.direct_runtime = runtime
        await runtime.start()
        self.direct_configuration_error = ""
        self._observe_presentation("runtime_started", runtime=runtime)
        return True
    except asyncio.CancelledError:
        if runtime is not None:
            await runtime.stop()
        if self.direct_runtime is runtime:
            self.direct_runtime = None
        raise
    except Exception as error:
        self.direct_configuration_error = type(error).__name__
        if runtime is not None:
            await runtime.stop()
        if self.direct_runtime is runtime:
            self.direct_runtime = None
        return False


async def _wait_for_transport(self) -> bool:
    # Race independently owned readiness, not direct behind a relay wait.
    if self.direct_runtime is not None and self.direct_runtime.available:
        return True
    direct = self._direct_start_task
    link = asyncio.create_task(self._wait_for_link_connection())
    pending = {link}
    if direct is not None:
        pending.add(direct)
    try:
        while pending:
            done, pending = await asyncio.wait(pending, return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                if task.result() and (task is link or
                        self.direct_runtime is not None and self.direct_runtime.available):
                    return True
        return False
    finally:
        if not link.done():
            link.cancel()
            await asyncio.gather(link, return_exceptions=True)


async def open_direct_session(self, context, agent_id: str, session_id: str):
    runtime = self.direct_runtime
    if runtime is None:
        raise ValueError("session snapshots are unavailable")
    route = runtime.reply_route(context)
    route.check_current()
    opener = self._direct_session_opener or self._open_session_snapshot
    view = await opener(runtime, context, agent_id, session_id)
    try:
        route.check_current()
        return view
    except BaseException:
        view.subscription.close()
        raise


async def dispatch_direct(self, context, payload: dict[str, Any]) -> dict[str, Any]:
    runtime = self.direct_runtime
    if runtime is None:
        raise ConnectionError("direct runtime unavailable")
    route = runtime.reply_route(context)
    body = dict(payload)
    for key, expected in (("targetHostId", route.owner.host_id),
                          ("targetDeviceId", route.owner.host_id)):
        if key in body and body.pop(key) != expected:
            raise ValueError("direct request target mismatch")
    # Claimed sender/epoch fields are never a substitute for the peer proof.
    if any(key in body for key in ("senderDeviceId", "senderEpoch", "hostEpoch", "peerEpoch")):
        raise ValueError("unexpected direct authority claims")
    if body.get("type") == "direct.enroll":
        raise ValueError("enrollment is available only through directed Link")
    capture = DirectResponseCapture(route)
    token = current_reply_route.set(capture.route())
    try:
        if (isinstance(body.get("type"), str) and body["type"].startswith("voice.")
                and body["type"] != "voice.speak.request"):
            return await self._dispatch_live_voice(context, body, route)
        try:
            inbound = parse_authenticated_payload(
                self.link_client, body, sender_device_id=route.owner.device_id,
                sender_epoch=route.owner.device_epoch, target_host_id=route.owner.host_id,
                target_device_id=route.owner.host_id)
        except AttachmentUnavailable as error:
            return self._user_message_result(error.message, status="failed",
                                             code="attachment_unavailable", message=str(error))
        route.check_current()
        if inbound is not None:
            request = getattr(inbound, "request", None) or getattr(inbound, "message", None)
            profile = getattr(request, "agent_id", None)
            session = getattr(request, "session_id", None)
            if profile and session:
                known = self._link_session_profiles.get(session)
                if known and known != profile:
                    raise ValueError("direct request profile contradicts session binding")
            await self.receive_link_payload(inbound)
        route.check_current()
        if isinstance(inbound, InboundLinkTurn):
            # This is admission, not a model final. Synchronous command output
            # is a separate reliable response, never a second receipt result.
            if capture.result is not None:
                await route.send(capture.result)
            return self._user_message_result(inbound.message, status="accepted")
        return capture.finish()
    finally:
        capture.closed = True
        current_reply_route.reset(token)


def _link_reply_route(self, device_id: str, device_epoch: int = 0) -> ReplyRoute:
    from .wiki_transport import authority_id
    client = self.link_client
    config = getattr(client, "config", None)
    generation = self._transport_generation
    if config is None:
        raise ConnectionError("Link owner unavailable")
    identity = runtime_owner(config)
    owner = AuthenticatedRequestOwner(authority_id(config), config.device_id,
        config.authorization_epoch, device_id, device_epoch, generation, "link", generation)
    def check():
        current = self._direct_current_config()
        if (self.link_client is not client or self._transport_generation != generation
                or current is None or runtime_owner(current) != identity):
            raise ConnectionError("Link response owner retired")
    async def send(payload):
        check()
        def checked_presentation():
            check()
            self._require_captured_draft(payload)
        if DIRECTED_FRAMES_CAPABILITY in set(getattr(client, "peer_capabilities", ())):
            return await client.send_payload(payload, target_device_id=device_id, owner_check=checked_presentation)
        return await client.send_payload(payload, owner_check=checked_presentation)
    return ReplyRoute(owner, check, send)


async def _send_link_payload(self, payload: dict[str, Any], *,
                             owner_check: Callable[[], None] | None = None,
                             reply_route: ReplyRoute | None = None) -> str:
    """Direct routes never fall through to Link, even after socket loss."""
    self._require_captured_draft(payload)
    route = reply_route or current_reply_route.get()
    if route is not None:
        if owner_check is not None:
            owner_check()
        result = await route.send(payload)
        if owner_check is not None:
            owner_check()
        return result
    client = self.link_client
    if client is None:
        raise ConnectionError("Loopdy Link is not configured")
    wait = getattr(client, "wait_until_connected", None)
    last_error: BaseException | None = None
    for attempt in range(2):
        if callable(wait):
            ready = await wait(timeout=20.0)
            if not ready:
                last_error = ConnectionError("Loopdy Link is not connected")
                continue
        elif not bool(getattr(client, "connected", False)):
            last_error = ConnectionError("Loopdy Link is not connected")
            continue
        try:
            def checked_presentation():
                if owner_check is not None:
                    owner_check()
                self._require_captured_draft(payload)
            checked_presentation()
            if owner_check is not None or (payload.get("delivery") == "draft" and
                    STATE_BACKED_PRESENTATION_CAPABILITY in set(getattr(client, "capabilities", ()))):
                return await client.send_payload(payload, owner_check=checked_presentation)
            return await client.send_payload(payload)
        except Exception as exc:
            if owner_check is not None:
                owner_check()
            pending_frame = getattr(client, "pending_payload_frame_id", None)
            if callable(pending_frame):
                frame_id = pending_frame(payload)
                if frame_id:
                    return str(frame_id)
            # Retry only failures that prove no matching durable frame owns
            # the payload. Other errors may be ambiguous and must surface.
            if isinstance(exc, ConnectionError):
                last_error = exc
                continue
            raise
    if last_error is not None:
        raise last_error
    raise ConnectionError("Loopdy Link control delivery failed")


async def _send_broker_payload(self, payload):
    client = self.link_client
    if client is None:
        raise ConnectionError("Loopdy Link is not configured")
    if payload.get("type") == "assistant.message" and payload.get("delivery") == "draft":
        self._require_captured_draft(payload)
        if STATE_BACKED_PRESENTATION_CAPABILITY in set(getattr(client, "capabilities", ())):
            return await client.send_payload(payload, owner_check=lambda: self._require_captured_draft(payload))
    return await client.send_payload(payload)
