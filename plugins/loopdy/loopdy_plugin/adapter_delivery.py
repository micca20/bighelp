"""Outbound messages, drafts, attachments, and notification delivery.

Operations use the calling LoopdyAdapter as their sole state/lifecycle owner.
Facade-owned callables and context variables are explicit call-time dependencies.
"""

from __future__ import annotations

import asyncio
import os
import time
from typing import Any, Dict, Optional
from gateway.platforms.base import SendResult
from .inbound_dispatch import current_turn_lease
from .control_replies import capture_control_reply
from .events import LoopdyEvent, build_event
from .link_contracts import assistant_message, notification_event
from .presentation import shape_notification


async def _deliver_link_notification(
    self,
    event: LoopdyEvent,
    *,
    target: str,
) -> SendResult:
    async with self._link_delivery_lock:
        return await self._deliver_link_notification_locked(event, target=target)


async def _deliver_link_notification_locked(
    self,
    event: LoopdyEvent,
    *,
    target: str,
) -> SendResult:
    await asyncio.to_thread(
        self.service.store.record_event,
        event,
        target=target,
    )
    existing = await asyncio.to_thread(
        self.service.store.get_event,
        event.event_id,
    )
    if existing is not None and existing.get("status") == "sent":
        return SendResult(success=True, message_id=event.event_id)
    sent_at = int((existing or {}).get("created_at") or time.time())
    push = shape_notification(event)
    payload = notification_event(
        event_id=event.event_id,
        event_type=event.type,
        agent_id=event.profile,
        agent_name=str(event.detail.get("agent_name") or event.profile),
        session_id=event.session_id,
        title=push.title,
        body=push.body,
        card=(
            event.detail.get("generative_ui")
            if isinstance(event.detail.get("generative_ui"), dict)
            else None
        ),
        sent_at=sent_at,
    )
    if existing is not None and existing.get("status") == "pending":
        client = self.link_client
        pending_frame = getattr(client, "pending_payload_frame_id", None)
        frame_id = pending_frame(payload) if callable(pending_frame) else None
        if frame_id:
            await asyncio.to_thread(
                self.service.store.mark_event_pending,
                event.event_id,
                frame_id,
            )
        else:
            await asyncio.to_thread(
                self.service.store.mark_event_delivered,
                event.event_id,
                str(existing.get("delivery_id") or ""),
            )
        return SendResult(success=True, message_id=event.event_id)
    try:
        frame_id = await self._send_link_payload(payload)
        client = self.link_client
        pending_frame = getattr(client, "pending_payload_frame_id", None)
        is_pending = callable(pending_frame) and pending_frame(payload) == frame_id
        marker = (
            self.service.store.mark_event_pending
            if is_pending
            else self.service.store.mark_event_delivered
        )
        await asyncio.to_thread(marker, event.event_id, frame_id)
        return SendResult(success=True, message_id=event.event_id)
    except Exception as exc:
        await asyncio.to_thread(
            self.service.store.mark_event_failed,
            event.event_id,
            type(exc).__name__,
        )
        return SendResult(
            success=False,
            error=f"Loopdy Link notification failed ({type(exc).__name__})",
        )


async def send(
    self, chat_id: str, content: str, reply_to: Optional[str] = None,
    metadata: Optional[Dict[str, Any]] = None, *, _channel_event, _is_link_chat_id, _text,
    profile_display_name,
) -> SendResult:
    if capture_control_reply(self, chat_id, content):
        # Command acceptance travels as user.message.result, never as an
        # assistant final that would seal the active draft/run.
        return SendResult(success=True)
    if self.link_client is not None and _is_link_chat_id(chat_id):
        if self._control_response_task.get() is asyncio.current_task():
            return SendResult(success=True)
        busy = self._busy_response.get()
        if (busy is not None and busy["task"] is asyncio.current_task()
                and busy["chat_id"] == chat_id and reply_to == busy["message_id"]):
            # This inline reply is a command acknowledgement, not the
            # running assistant final. The originating submission receipt
            # owns its admission; retain bounded text for diagnostics only.
            busy["response"] = str(content)[:2000]
            return SendResult(success=True)
        values = dict(metadata or {})
        inherited_lease = current_turn_lease.get()
        if reply_to:
            values["reply_to_message_id"] = reply_to
        elif inherited_lease is not None and not values.get("reply_to_message_id"):
            values["reply_to_message_id"] = inherited_lease.message_id
        is_interim = values.get("_interim_send") is True
        try:
            route = self._response_route(chat_id, values, reply_to)
            agent_id = self._link_response_profile(chat_id, values)
            agent_name = (
                _text(values.get("agent_name") or values.get("sender_name"), 80)
                or profile_display_name(agent_id)
            )
            active_draft = None if is_interim else self._active_link_draft(
                chat_id, values
            )
            requested_message_id = _text(values.get("_loopdy_message_id"), 180)
            message_id = (
                requested_message_id
                or (active_draft[1] if active_draft else self._new_message_id())
            )
            payload = assistant_message(
                    message_id=message_id,
                    session_id=chat_id,
                    text=content,
                    sent_at=int(time.time()),
                    agent_name=agent_name,
                    agent_id=agent_id,
                    delivery=(
                        "draft" if is_interim else "final"
                    ),
                    draft_id=(
                        int.from_bytes(os.urandom(6), "big") or 1
                        if is_interim
                        else None
                    ),
                )
            self._observe_presentation("assistant_message", payload=payload,
                profile=agent_id, session_id=chat_id, lease=current_turn_lease.get(),
                reply_to=values.get("reply_to_message_id"), final=not is_interim)
            await self._send_link_payload(payload, reply_route=route)
            if active_draft is not None:
                self._finish_link_draft(chat_id, values, active_draft[0])
            if not is_interim and self.activity_broker is not None:
                try:
                    await self.activity_broker.complete(
                        chat_id,
                        agent_name=agent_name,
                        succeeded=True,
                    )
                except Exception:
                    pass
            return SendResult(success=True, message_id=message_id)
        except Exception as exc:
            return SendResult(
                success=False,
                error=f"Loopdy Link delivery failed ({type(exc).__name__})",
            )
    target = str(chat_id or self.home_target or "all").strip()
    event = _channel_event(content, metadata=metadata, target=target)
    # A validated card is atomic even when its JSON exceeds the text limit.
    if "generative_ui" not in event.detail and len(content) > 50_000:
        result = SendResult(success=True)
        for offset in range(0, len(content), 50_000):
            result = await self.send(
                chat_id, content[offset:offset + 50_000],
                reply_to=reply_to, metadata=metadata,
            )
            if not result.success:
                return result
        return result
    if self.link_client is not None and target in {"all", "home"}:
        return await self._deliver_link_notification(event, target=target)
    result = await asyncio.to_thread(self.service.deliver, event, target=target)
    if result.get("success"):
        message_id = str(result.get("message_id") or event.event_id)
        return SendResult(success=True, message_id=message_id)
    return SendResult(
        success=False,
        error=str(result.get("error") or "Loopdy delivery failed"),
    )


async def _send_link_attachment(
    self,
    *,
    chat_id: str,
    path: str,
    caption: str | None,
    reply_to: str | None,
    metadata: Dict[str, Any] | None, _is_link_chat_id) -> SendResult:
    if self.link_client is None or not _is_link_chat_id(chat_id):
        return SendResult(success=False, error="Loopdy Link is not connected")
    safe_path = self.validate_media_delivery_path(path)
    if safe_path is None:
        return SendResult(success=False, error="Loopdy attachment path is unavailable")
    content = f"{caption}\nMEDIA:{safe_path}" if caption else f"MEDIA:{safe_path}"
    values = dict(metadata or {})
    try:
        agent_id = self._link_response_profile(chat_id, values)
        message_id = self._new_message_id()
        backend = getattr(self.workspace_controller, "backend", None)
        attachment_store = getattr(backend, "attachment_store", None)
        resolve = getattr(attachment_store, "resolve", None)
        if not callable(resolve):
            return SendResult(
                success=False,
                error="Loopdy attachment storage is unavailable",
            )
        resolved = await asyncio.to_thread(
            resolve,
            profile=agent_id,
            session_id=chat_id,
            items=[{"id": message_id, "text": content}],
        )
        if (
            not isinstance(resolved, list)
            or len(resolved) != 1
            or not resolved[0].get("attachments")
        ):
            return SendResult(
                success=False,
                error="Loopdy attachment could not be cached",
            )
        values["_loopdy_message_id"] = message_id
    except Exception as exc:
        return SendResult(
            success=False,
            error=f"Loopdy attachment caching failed ({type(exc).__name__})",
        )
    return await self.send(
        chat_id=chat_id,
        content=content,
        reply_to=reply_to,
        metadata=values,
    )


async def send_clarify(
    self, chat_id: str, question: str, choices: Optional[list], clarify_id: str,
    session_key: str, metadata: Optional[Dict[str, Any]] = None, *, _active_profile_id, _text,
    logger, profile_display_name, base_send_clarify,
) -> SendResult:
    """Render Hermes' prompt, then enqueue one request-bound Home card."""
    from tools.clarify_gateway import (
        get_clarify_timeout,
        get_pending_for_session,
    )

    canonical_id = _text(clarify_id, 180)
    canonical_session = _text(session_key, 180)
    canonical_chat = _text(chat_id, 180)
    canonical_question = _text(question, 2_000)
    values = metadata or {}
    profile = (
        _text(values.get("profile") or values.get("profile_name"), 80)
        or _active_profile_id()
    )
    agent_name = (
        _text(values.get("agent_name") or values.get("sender_name"), 80)
        or profile_display_name(profile)
    )

    async def publish_managed_clarification() -> None:
        """Publish only from Hermes' exact session row and observed hook turn."""
        try:
            store = getattr(self, "_session_store", None)
            lookup = getattr(store, "lookup_by_session_key", None)
            if not callable(lookup):
                raise RuntimeError("Hermes session index is unavailable")

            def resolve_and_publish() -> None:
                entry = lookup(canonical_session)
                stored_session_id = str(getattr(entry, "session_id", "") or "").strip()
                entry_key = str(getattr(entry, "session_key", "") or "").strip()
                origin = getattr(entry, "origin", None)
                session_profile = str(getattr(origin, "profile", "") or "").strip()
                platform = getattr(getattr(origin, "platform", None), "value", None)
                if (entry_key != canonical_session or not stored_session_id
                        or session_profile != profile or platform != "loopdy"):
                    raise RuntimeError("Hermes clarification session metadata is unavailable")
                from .managed_notifications import get_managed_notifications
                get_managed_notifications().publish_observed_clarification(
                    profile=session_profile,
                    session_id=stored_session_id,
                    request_id=canonical_id,
                    question=canonical_question,
                )

            await asyncio.to_thread(resolve_and_publish)
        except Exception as error:
            # The actionable Hermes prompt has already been presented. Never
            # fail or duplicate it because optional push projection is absent.
            code = str(getattr(error, "code", "") or type(error).__name__)
            logger.warning("Managed clarification notification unavailable (%s)", code[:96])

    voice = self._live_voice_runtime
    if voice is not None and await voice.clarification(
            chat_id=chat_id, question=question, clarify_id=clarify_id,
            session_key=session_key, lease=current_turn_lease.get()):
        await publish_managed_clarification()
        return SendResult(success=True, message_id=clarify_id)

    normalized_choices = [
        value
        for value in (_text(choice, 500) for choice in list(choices or ())[:4])
        if value
    ]
    pending = get_pending_for_session(
        canonical_session,
        include_choice_prompts=True,
    )
    multi_select = bool(
        pending is not None
        and str(getattr(pending, "clarify_id", "")) == canonical_id
        and getattr(pending, "multi_select", False)
    )
    try:
        timeout = int(get_clarify_timeout())
    except (TypeError, ValueError):
        timeout = 3_600
    expires_at = int(time.time()) + timeout if timeout > 0 else None
    interaction = {
        "schemaVersion": 1,
        "type": "clarify",
        "requestId": canonical_id,
        "expiresAt": expires_at,
        "allowsCustomResponse": True,
        "questions": [
            {
                "id": "q0",
                "question": canonical_question,
                "choices": normalized_choices,
                "multiSelect": multi_select,
                "allowsCustomResponse": True,
            }
        ],
    }
    detail = {
        "kind": "clarify",
        "request_id": canonical_id,
        "session_key": canonical_session,
        "question": canonical_question,
        "interaction": interaction,
        **({"expires_at": str(expires_at)} if expires_at is not None else {}),
        **({"agent_name": agent_name} if agent_name else {}),
    }
    event = build_event(
        "attention.required",
        correlation=("clarify", canonical_id, canonical_session),
        profile=profile,
        session_id=canonical_chat,
        detail=detail,
    )
    target = self.home_target or "all"
    if self.link_client is not None:
        async with self._link_delivery_lock:
            existing = await asyncio.to_thread(
                self.service.store.get_event,
                event.event_id,
            )
            status = str((existing or {}).get("status") or "")
            prompt_message_id = "message_" + event.event_id.rsplit(":", 1)[-1]
            if status == "sent":
                await publish_managed_clarification()
                return SendResult(success=True, message_id=prompt_message_id)
            if existing is None:
                prompt_metadata = dict(metadata or {})
                prompt_metadata["_loopdy_message_id"] = prompt_message_id
                result = await base_send_clarify(
                    chat_id=chat_id,
                    question=question,
                    choices=choices,
                    clarify_id=clarify_id,
                    session_key=session_key,
                    metadata=prompt_metadata,
                )
                if not result.success:
                    return result
                await asyncio.to_thread(
                    self.service.store.record_event,
                    event,
                    target=target,
                )
                await asyncio.to_thread(
                    self.service.store.mark_event_prompted,
                    event.event_id,
                )
            else:
                result = SendResult(success=True, message_id=prompt_message_id)
                if status == "queued":
                    await asyncio.to_thread(
                        self.service.store.mark_event_prompted,
                        event.event_id,
                    )
            await publish_managed_clarification()
            delivery = await self._deliver_link_notification_locked(
                event,
                target=target,
            )
            return result if delivery.success else delivery

    result = await base_send_clarify(
        chat_id=chat_id,
        question=question,
        choices=choices,
        clarify_id=clarify_id,
        session_key=session_key,
        metadata=metadata,
    )
    if not result.success:
        return result
    await publish_managed_clarification()
    self.service.enqueue(event, target=target)
    return result


async def send_draft(
    self, chat_id: str, draft_id: int, content: str, metadata: Dict[str, Any] | None = None, *,
    _LINK_DRAFT_MINIMUM_INTERVAL_SECONDS, _is_link_chat_id, _text, profile_display_name,
) -> SendResult:
    if self.link_client is None or not _is_link_chat_id(chat_id):
        return SendResult(success=False, error="Loopdy Link is not connected")
    values = dict(metadata or {})
    try:
        route = self._response_route(chat_id, values)
        lease = current_turn_lease.get()
        if lease is not None and not values.get("reply_to_message_id"):
            values["reply_to_message_id"] = lease.message_id
        agent_id = self._link_response_profile(chat_id, values)
        draft_key = (str(chat_id), int(draft_id))
        turn_key = self._link_draft_turn_key(chat_id, values)
        previous = self._link_active_drafts.pop(turn_key, None)
        message_id = (
            previous[1]
            if previous is not None
            else self._link_draft_messages.get(draft_key)
        )
        if message_id is None:
            message_id = self._new_message_id()
        self._link_draft_messages[draft_key] = message_id
        self._link_draft_messages.move_to_end(draft_key)
        self._link_active_drafts[turn_key] = (draft_key, message_id)
        if previous is not None and previous[0] != draft_key:
            self._link_draft_messages.pop(previous[0], None)
        self._trim_link_draft_identities()
        payload = assistant_message(
            message_id=message_id, session_id=chat_id, text=content,
            sent_at=int(time.time()), agent_name=(
                _text(values.get("agent_name") or values.get("sender_name"), 80)
                or profile_display_name(agent_id)), agent_id=agent_id,
            delivery="draft", draft_id=draft_id)
        self._observe_presentation("assistant_message", payload=payload,
            profile=agent_id, session_id=chat_id, lease=current_turn_lease.get(),
            reply_to=values.get("reply_to_message_id"), final=False)
        self._require_captured_draft(payload)
        now = time.monotonic()
        last_sent_at = self._link_draft_sent_at.get(turn_key)
        if (
            last_sent_at is not None
            and now - last_sent_at < _LINK_DRAFT_MINIMUM_INTERVAL_SECONDS
        ):
            # The final response carries the complete text. Intermediate
            # token snapshots are presentation hints, so bound Link/APNs
            # backlog without weakening durable final/tool history.
            return SendResult(success=True)
        await self._send_link_payload(payload, reply_route=route)
        self._link_draft_sent_at[turn_key] = now
        self._link_draft_sent_at.move_to_end(turn_key)
        return SendResult(success=True)
    except Exception as exc:
        return SendResult(
            success=False,
            error=f"Loopdy Link draft failed ({type(exc).__name__})",
        )


def _link_draft_turn_key(
    chat_id: str, metadata: Dict[str, Any], *, _text) -> tuple[str, str]:
    reply_to = _text(metadata.get("reply_to_message_id"), 180)
    return (str(chat_id), reply_to)


def _active_link_draft(
    self, chat_id: str, metadata: Dict[str, Any]
) -> tuple[tuple[str, int], str] | None:
    key = self._link_draft_turn_key(chat_id, metadata)
    active = self._link_active_drafts.get(key)
    if active is not None:
        self._link_active_drafts.move_to_end(key)
    return active


def _finish_link_draft(
    self,
    chat_id: str,
    metadata: Dict[str, Any],
    draft_key: tuple[str, int],
) -> None:
    turn_key = self._link_draft_turn_key(chat_id, metadata)
    self._link_active_drafts.pop(turn_key, None)
    self._link_draft_sent_at.pop(turn_key, None)
    self._link_draft_messages.pop(draft_key, None)


def _trim_link_draft_identities(self, *, _MAX_LINK_DRAFT_IDENTITIES) -> None:
    while len(self._link_draft_messages) > _MAX_LINK_DRAFT_IDENTITIES:
        stale_key, _ = self._link_draft_messages.popitem(last=False)
        for turn_key, active in tuple(self._link_active_drafts.items()):
            if active[0] == stale_key:
                self._link_active_drafts.pop(turn_key, None)
                self._link_draft_sent_at.pop(turn_key, None)
    while len(self._link_active_drafts) > _MAX_LINK_DRAFT_IDENTITIES:
        turn_key, active = self._link_active_drafts.popitem(last=False)
        self._link_draft_sent_at.pop(turn_key, None)
        self._link_draft_messages.pop(active[0], None)
