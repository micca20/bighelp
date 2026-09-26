"""Stored sessions, bounded history and session-bound artifact delivery."""

from __future__ import annotations

import asyncio
import base64
import inspect
import json
import sqlite3
from typing import Any
from .generated_media import resolve_generated_media
from .link_contracts import MAX_AGENT_ATTACHMENT_BYTES, MAX_ATTACHMENT_CHUNK_BYTES, _workspace_json
from .session_state import SessionStateReader, SessionStateNotFound, SessionStateResetRequired, SessionStateUnavailable
from .workspace_common import (
    WorkspaceControlError,
    _agent_id,
    _coordinate,
    _nonnegative_integer,
    _object,
    _optional_coordinate,
    _text,
    _timestamp,
    _utf8_prefix,
    logger,
)
from .workspace_projects import (
    _session_workspace_identity,
)


_HISTORY_ROLES = frozenset({"user", "assistant", "tool"})

_HISTORY_RICH_FIELDS = (
    "tool_call_id",
    "tool_calls",
    "tool_name",
    "effect_disposition",
    "timestamp",
    "token_count",
    "finish_reason",
    "reasoning",
    "reasoning_content",
    "reasoning_details",
    "codex_reasoning_items",
    "codex_message_items",
    "platform_message_id",
    "_compressed_summary",
    "display_kind",
    "display_metadata",
    "compacted",
)

_SESSION_HISTORY_OFFSET_LIMIT = 10_000_000

_SESSION_HISTORY_RESPONSE_MAX_BYTES = 160_000


def _reconcile_session_presentation(state: dict[str, Any], live: Any) -> dict[str, Any]:
    """Reconcile only exact transport identities; never infer text/time lineage."""
    if (not isinstance(live, dict) or set(live) != {"coverageCursor", "events", "complete"}
            or type(live["coverageCursor"]) is not int or live["coverageCursor"] < 0
            or live["complete"] is not True or not isinstance(live["events"], list)
            or len(live["events"]) > 128):
        raise ValueError("Current presentation is incomplete or invalid")
    rows = state.get("messages", [])
    canonical = {}
    # A canonical assistant after the newest visible user might be the final
    # for this overlay. Missing identity must not be 'solved' by text or time.
    ambiguous_tail = False
    for row in rows:
        if row.get("role") == "user":
            ambiguous_tail = False
        if row.get("role") != "assistant":
            continue
        identity = row.get("platform_message_id")
        if isinstance(identity, str) and identity:
            if identity in canonical:
                raise SessionStateResetRequired("Canonical platform identity is ambiguous")
            canonical[identity] = row
        elif not row.get("tool_calls") and row.get("display_kind") != "hidden" and not row.get("_compressed_summary"):
            ambiguous_tail = True
    events = []
    identities = set()
    for event in live["events"]:
        if (not isinstance(event, dict) or event.get("sessionId") != state.get("sessionId")
                or event.get("agentId", state.get("agentId")) != state.get("agentId")):
            raise ValueError("Presentation scope contradicts canonical state")
        if event.get("type") == "assistant.message":
            identity = event.get("messageId")
            if not isinstance(identity, str) or not identity or identity in identities:
                raise SessionStateResetRequired("Presentation message identity is ambiguous")
            identities.add(identity)
            if identity in canonical:
                # Hermes already owns this exact message, including a draft
                # whose final was persisted before its delivery hook ran.
                continue
            if event.get("delivery") != "draft" or ambiguous_tail:
                raise SessionStateResetRequired("Presentation needs exact canonical reconciliation")
        events.append(event)
    return {"coverageCursor": live["coverageCursor"], "events": events, "complete": True}


def _stored_session_id_for_visible(
    catalog: dict[str, Any], visible_id: str
) -> str | None:
    rows = catalog.get("sessions")
    if not isinstance(rows, list):
        return None
    # A durable id always wins over a chat alias. This keeps reset siblings
    # independently addressable even when a legacy chat id happens to collide
    # with another row's stored coordinate.
    for row in rows:
        if not isinstance(row, dict):
            continue
        stored_id = row.get("id")
        if stored_id == visible_id:
            try:
                return _coordinate(stored_id, 160)
            except WorkspaceControlError:
                return None
    for row in rows:
        if not isinstance(row, dict) or row.get("chat_id") != visible_id:
            continue
        try:
            return _coordinate(row.get("id"), 160)
        except WorkspaceControlError:
            return None
    return None


class SessionControls:
    async def sessions_list(self, payload: dict[str, Any]) -> dict[str, Any]:
        values = _object(payload, "workspace payload")
        if set(values) - {"agentId"}:
            raise WorkspaceControlError("Session list payload is invalid")
        agent_id = _agent_id(values["agentId"]) if "agentId" in values else None
        raw = _object(await self._session_catalog(agent_id), "Hermes session catalog")
        rows = raw.get("sessions")
        if not isinstance(rows, list) or len(rows) > 500:
            raise WorkspaceControlError("Hermes session catalog is invalid")
        sources = [_object(row, "Hermes session") for row in rows]
        sources.sort(
            key=lambda source: (
                _timestamp(source.get("last_active", source.get("started_at"))),
                _timestamp(source.get("started_at")),
                _coordinate(source.get("id"), 160),
            ),
            reverse=True,
        )
        sessions = []
        project_catalogs: dict[str, dict[str, Any]] = {}
        stored_ids: set[str] = set()
        for source in sources:
            stored_id = _coordinate(source.get("id"), 160)
            if stored_id in stored_ids:
                raise WorkspaceControlError("Hermes session coordinates are ambiguous")
            stored_ids.add(stored_id)
        visible_ids: set[str] = set()
        for source in sources:
            stored_id = _coordinate(source.get("id"), 160)
            profile = _agent_id(source.get("profile"))
            workspace_id = None
            workspace_name = None
            if source.get("cwd") not in (None, ""):
                if profile not in project_catalogs:
                    project_catalogs[profile] = _object(
                        await self._projects_catalog(profile),
                        "Hermes project catalog",
                    )
                workspace_id, workspace_name = _session_workspace_identity(
                    source.get("cwd"), project_catalogs[profile]
                )
            session_source = _coordinate(source.get("source", "local"), 64)
            chat_id = _optional_coordinate(source.get("chat_id"), 160)
            preferred_visible_id = (
                chat_id if session_source == "loopdy" and chat_id else stored_id
            )
            # A model/reset boundary can create a second durable Hermes row
            # for the same Loopdy chat id. They are distinct transcripts and
            # must both remain resumable. The catalog is ordered newest-first,
            # so the current row keeps the stable chat alias and older rows use
            # their exact durable id. Never let an alias occupy another row's
            # durable coordinate.
            visible_id = (
                preferred_visible_id
                if preferred_visible_id not in visible_ids
                and (
                    preferred_visible_id == stored_id
                    or preferred_visible_id not in stored_ids
                )
                else stored_id
            )
            if visible_id in visible_ids:
                raise WorkspaceControlError("Hermes session coordinates are ambiguous")
            visible_ids.add(visible_id)
            is_active = source.get("is_active") is True
            if session_source == "loopdy" and callable(self.session_active_getter):
                resolved_active = self.session_active_getter(
                    profile,
                    preferred_visible_id,
                    stored_id,
                )
                if inspect.isawaitable(resolved_active):
                    resolved_active = await resolved_active
                is_active = resolved_active is True
            goal = None
            if session_source == "loopdy" and callable(self.session_goal_getter):
                goal = self.session_goal_getter(profile, preferred_visible_id, stored_id)
                if inspect.isawaitable(goal):
                    goal = await goal
            # Keep direct model generation distinct from delegated execution.
            # This read follows the authenticated, profile-scoped catalog row,
            # and never substitutes its potentially reused chat alias as owner.
            subagents = (
                self.session_subagents_getter(profile, stored_id, visible_id)
                if callable(self.session_subagents_getter) else None
            )
            sessions.append(
                {
                    **({"subagents": subagents} if subagents is not None else {}),
                    **({"goal": goal} if goal is not None else {}),
                    "storedId": stored_id,
                    "profile": profile,
                    "source": session_source,
                    "chatId": chat_id,
                    "visibleId": visible_id,
                    "title": _text(
                        source.get("title", "Hermes session"), 240, allow_empty=True
                    )
                    or "Hermes session",
                    "preview": _text(source.get("preview"), 4_096, allow_empty=True),
                    "messageCount": _nonnegative_integer(
                        source.get("message_count", 0), maximum=10_000_000
                    ),
                    "startedAt": _timestamp(source.get("started_at")),
                    "lastActive": _timestamp(
                        source.get("last_active", source.get("started_at"))
                    ),
                    "isActive": is_active,
                    "isPinned": source.get("pinned") is True,
                    "workspaceId": workspace_id,
                    "workspaceName": workspace_name,
                }
            )
        return {"sessions": sessions}

    async def sessions_update(self, payload: dict[str, Any]) -> dict[str, Any]:
        values = _object(payload, "workspace payload")
        required = {"storedId", "agentId"}
        allowed = required | {"title", "pinned", "archived"}
        if not required.issubset(values) or set(values) - allowed:
            raise WorkspaceControlError("Session update payload is invalid")
        updates = set(values) - required
        if not updates:
            raise WorkspaceControlError("Session update payload is invalid")
        stored_id = _coordinate(values.get("storedId"), 160)
        agent_id = _agent_id(values.get("agentId"))
        body: dict[str, Any] = {"profile": agent_id}
        if "title" in values:
            title = _text(values.get("title"), 400).strip()
            if not title or len(title) > 100:
                raise WorkspaceControlError("Session title is invalid")
            body["title"] = title
        for key in ("pinned", "archived"):
            if key in values:
                if not isinstance(values[key], bool):
                    raise WorkspaceControlError("Session update payload is invalid")
                body[key] = values[key]

        target_id = stored_id
        try:
            await self._session_update(target_id, body)
        except Exception as exc:
            if getattr(exc, "status_code", None) != 404:
                raise
            catalog = _object(
                await self._session_catalog(agent_id),
                "Hermes session catalog",
            )
            target_id = _stored_session_id_for_visible(catalog, stored_id) or ""
            if not target_id or target_id == stored_id:
                raise
            await self._session_update(target_id, body)
        return {
            "storedId": stored_id,
            "agentId": agent_id,
            "updated": True,
        }

    async def sessions_delete(self, payload: dict[str, Any]) -> dict[str, Any]:
        values = _object(payload, "workspace payload")
        if set(values) != {"storedId", "agentId"}:
            raise WorkspaceControlError("Session delete payload is invalid")
        stored_id = _coordinate(values.get("storedId"), 160)
        agent_id = _agent_id(values.get("agentId"))

        target_id = stored_id
        try:
            await self._session_delete(target_id, agent_id)
        except Exception as exc:
            if getattr(exc, "status_code", None) != 404:
                raise
            catalog = _object(
                await self._session_catalog(agent_id),
                "Hermes session catalog",
            )
            target_id = _stored_session_id_for_visible(catalog, stored_id) or ""
            if not target_id or target_id == stored_id:
                raise
            await self._session_delete(target_id, agent_id)
        try:
            delete_durations = getattr(getattr(self.service, "store", None), "delete_turn_durations", None)
            if callable(delete_durations):
                delete_durations(target_id)
        except Exception as exc:
            logger.warning("Loopdy turn duration cleanup failed (%s)", type(exc).__name__)
        return {
            "storedId": stored_id,
            "agentId": agent_id,
            "deleted": True,
        }

    async def _session_runtime(self, stored_id: str, agent_id: str) -> dict[str, str] | None:
        """Optional display-only metadata. Never export the underlying model config."""
        try:
            detail = await self._session_detail(stored_id, agent_id)
            if detail.get("id") != stored_id or detail.get("profile") != agent_id:
                return None
            from hermes_state import SessionDB

            runtime = {"model": detail.get("model")}
            provider = SessionDB.session_gateway_runtime(detail).get("provider")
            if provider:
                runtime["provider"] = provider
            if self.session_runtime_getter is not None:
                override = await self.session_runtime_getter(agent_id, stored_id)
                if override and override.get("model"):
                    runtime = override
            result = {"model": _text(runtime.get("model"), 160, allow_empty=False)}
            if runtime.get("provider"):
                result["provider"] = _text(runtime["provider"], 128, allow_empty=False)
            return result
        except Exception:
            # Unavailable/legacy optional metadata must not strand history.
            return None

    async def _presentation_session_id(self, agent_id: str, stored_id: str) -> str:
        """Resolve a visible feed only from the exact profile's bounded catalog."""
        catalog = _object(await self._session_catalog(agent_id), "Hermes session catalog")
        rows = catalog.get("sessions")
        if not isinstance(rows, list) or len(rows) > 500:
            raise SessionStateUnavailable("Session presentation catalog unavailable")
        matches = [row for row in rows if isinstance(row, dict) and row.get("id") == stored_id]
        if len(matches) != 1:
            raise SessionStateUnavailable("Exact session presentation binding unavailable")
        row = matches[0]
        if row.get("profile", agent_id) != agent_id:
            raise SessionStateResetRequired("Session presentation profile changed")
        visible_id = row.get("chat_id") or stored_id
        visible_id = _coordinate(visible_id, 180)
        # Reset siblings can share a legacy chat coordinate. Do not attach the
        # active overlay to an arbitrary historical sibling just because it was
        # the first catalog row, and never trust a caller-supplied alias pair.
        owners = {item.get("id") for item in rows if isinstance(item, dict)
                  and (item.get("chat_id") or item.get("id")) == visible_id}
        if owners != {stored_id}:
            raise SessionStateResetRequired("Session presentation alias is ambiguous")
        return visible_id

    async def sessions_state(self, payload: dict[str, Any]) -> dict[str, Any]:
        """Opt-in canonical pages; never fall back to a legacy full transcript."""
        values = _object(payload, "workspace payload")
        if not {"storedId", "agentId"}.issubset(values) or set(values) - {"storedId", "agentId", "cursor"}:
            raise WorkspaceControlError("Session state payload is invalid", code="session_state_invalid")
        try:
            stored_id = _coordinate(values["storedId"], 160)
            agent_id = _agent_id(values["agentId"])
        except WorkspaceControlError as exc:
            raise WorkspaceControlError("Session state scope is invalid.", code="session_state_invalid") from exc
        cursor = values.get("cursor")
        reader = SessionStateReader()
        try:
            try:
                result = await reader.read_profile(agent_id=agent_id, stored_id=stored_id, cursor=cursor)
            except SessionStateNotFound:
                if cursor is not None:
                    raise
                catalog = _object(await self._session_catalog(agent_id), "Hermes session catalog")
                resolved = _stored_session_id_for_visible(catalog, stored_id)
                if resolved is None or resolved == stored_id:
                    raise
                result = await reader.read_profile(agent_id=agent_id, stored_id=resolved)
        except SessionStateResetRequired as exc:
            raise WorkspaceControlError("Session changed. Reload its current state.",
                                        code="session_state_reset", status="conflict") from exc
        except SessionStateUnavailable as exc:
            raise WorkspaceControlError("Hermes session state is not ready.", code="session_state_unavailable") from exc
        except ValueError as exc:
            raise WorkspaceControlError("Session state coordinate is invalid.", code="session_state_invalid") from exc
        result["sessionId"] = stored_id
        if cursor is None:
            runtime = await self._session_runtime(result["storedId"], agent_id)
            if runtime:
                result["runtime"] = runtime
            if self.session_presentation_getter is not None:
                try:
                    # Capture the live checkpoint between two canonical reads.
                    # A direct caller subscribes before this operation; events
                    # after coverageCursor remain in that bounded subscription.
                    visible_id = await self._presentation_session_id(agent_id, result["storedId"])
                    if stored_id != result["storedId"] and stored_id != visible_id:
                        raise SessionStateResetRequired("Requested session alias changed")
                    result["sessionId"] = visible_id
                    live = self.session_presentation_getter(agent_id, visible_id)
                    checked = await reader.read_profile(agent_id=agent_id, stored_id=result["storedId"])
                    checked_visible = await self._presentation_session_id(agent_id, result["storedId"])
                    if (checked_visible != visible_id
                            or checked.get("storedId") != result.get("storedId")
                            or checked.get("agentId") != result.get("agentId")
                            or checked.get("revision") != result.get("revision")):
                        raise SessionStateResetRequired("Canonical session changed during live snapshot")
                    result["live"] = _reconcile_session_presentation(result, live)
                    # Check the combined payload against the real wire bound,
                    # including nesting, rather than adding two independent caps.
                    _workspace_json(result, depth=0)
                except SessionStateResetRequired as exc:
                    raise WorkspaceControlError("Session changed. Reload its current state.",
                                                code="session_state_reset", status="conflict") from exc
                except (ValueError, ConnectionError, SessionStateUnavailable) as exc:
                    raise WorkspaceControlError("Current session presentation is not ready.",
                                                code="session_state_unavailable") from exc
            else:
                # Standalone/custom backends without the adapter collaborator
                # cannot assert that an empty overlay covers a running turn.
                result["live"] = {"coverageCursor": 0, "events": [], "complete": False}
        return result

    async def sessions_content(self, payload: dict[str, Any]) -> dict[str, Any]:
        values = _object(payload, "workspace payload")
        if not {"storedId", "agentId", "reference"}.issubset(values) or set(values) - {"storedId", "agentId", "reference", "offset"}:
            raise WorkspaceControlError("Session content payload is invalid", code="session_state_invalid")
        try:
            stored_id = _coordinate(values["storedId"], 160)
            agent_id = _agent_id(values["agentId"])
        except WorkspaceControlError as exc:
            raise WorkspaceControlError("Session content scope is invalid.", code="session_state_invalid") from exc
        try:
            return await SessionStateReader().content_profile(
                agent_id=agent_id, stored_id=stored_id, reference=values["reference"], offset=values.get("offset", 0),
            )
        except SessionStateResetRequired as exc:
            raise WorkspaceControlError("Session content changed. Reload its current state.",
                                        code="session_state_reset", status="conflict") from exc
        except ValueError as exc:
            raise WorkspaceControlError("Session content coordinate is invalid.", code="session_state_invalid") from exc

    async def sessions_history(self, payload: dict[str, Any]) -> dict[str, Any]:
        values = _object(payload, "workspace payload")
        required = {"storedId", "agentId"}
        if not required.issubset(values) or set(values) - required - {"offset", "turnLimit"}:
            raise WorkspaceControlError("Session history payload is invalid")
        stored_id = _coordinate(values.get("storedId"), 160)
        agent_id = _agent_id(values.get("agentId"))
        offset = _nonnegative_integer(
            values.get("offset", 0),
            maximum=_SESSION_HISTORY_OFFSET_LIMIT,
        )
        turn_limit = None
        if "turnLimit" in values:
            turn_limit = _nonnegative_integer(values["turnLimit"], maximum=10)
            if turn_limit < 1:
                raise WorkspaceControlError("Session history turn limit is invalid")
        history_options: dict[str, Any] = {"include_compacted": True}
        if "offset" in values:
            history_options["offset"] = offset
        try:
            raw = _object(
                await self._session_messages(
                    stored_id,
                    agent_id,
                    **history_options,
                ),
                "Hermes session history",
            )
        except Exception as exc:
            # Loopdy shows chat_id as its stable visible coordinate, while
            # Hermes' history endpoint resolves the stored session id. Use
            # the official, profile-scoped catalog to bridge that alias on
            # reopen; never infer an id from transcript text or a prefix.
            if getattr(exc, "status_code", None) != 404:
                raise
            catalog = _object(
                await self._session_catalog(agent_id),
                "Hermes session catalog",
            )
            resolved = _stored_session_id_for_visible(catalog, stored_id)
            if resolved is None:
                raise
            stored_id = resolved
            raw = _object(
                await self._session_messages(
                    stored_id,
                    agent_id,
                    **history_options,
                ),
                "Hermes session history",
            )
        rows = raw.get("messages")
        if not isinstance(rows, list) or len(rows) > 500:
            raise WorkspaceControlError("Hermes session history is invalid")
        runtime = None
        if offset == 0 and raw.get("session_id", stored_id) == stored_id:
            runtime = await self._session_runtime(stored_id, agent_id)
        runtime_fields: dict[str, Any] = {"runtime": runtime} if runtime else {}
        if offset == 0 and raw.get("session_id", stored_id) == stored_id and callable(self.session_subagents_getter):
            runtime_fields["subagents"] = self.session_subagents_getter(agent_id, stored_id, stored_id)
        duration_reader = getattr(getattr(self.service, "store", None), "turn_durations", None)
        try:
            durations = duration_reader(stored_id) if callable(duration_reader) else {}
        except (OSError, sqlite3.Error):
            durations = {}
        if not isinstance(durations, dict) or raw.get("session_id", stored_id) != stored_id:
            durations = {}
        # Page-local uniqueness cannot distinguish another completion on a
        # different page. If the canonical read is unavailable, leave timing unknown.
        unique_timestamps = await self._session_unique_final_timestamps(stored_id, agent_id) if durations else set()
        messages_by_row: dict[int, dict[str, Any]] = {}
        for index, row in enumerate(rows):
            if not isinstance(row, dict):
                continue
            role = row.get("role")
            if not isinstance(role, str) or role not in _HISTORY_ROLES:
                continue
            # Hermes includes a display_content field on every row, but it is
            # intentionally null for compacted rows that still carry their
            # user-visible text in content. Prefer the display projection
            # when it is non-empty and fall back to the persisted content
            # otherwise. Hermes can send an empty display projection for a
            # row that still has user-visible text in content.
            display_content = row.get("display_content")
            content = (
                display_content
                if isinstance(display_content, str) and display_content != ""
                else row.get("content")
            )
            if not isinstance(content, str) or len(content.encode("utf-8")) > 1_000_000:
                continue
            raw_id = row.get("id", index + 1)
            message_id = (
                str(raw_id)
                if isinstance(raw_id, int) and not isinstance(raw_id, bool)
                else _coordinate(raw_id, 128)
            )
            message: dict[str, Any] = {
                "id": message_id,
                "role": role,
                "content": content,
            }
            if isinstance(raw_id, int) and not isinstance(raw_id, bool):
                # The mobile projection uses the numeric row coordinate to
                # reconcile history with live events and tool results.
                message["row_id"] = raw_id
            for field in _HISTORY_RICH_FIELDS:
                value = row.get(field)
                if value is None:
                    continue
                if isinstance(value, str) and len(value.encode("utf-8")) > 256_000:
                    value = _utf8_prefix(value, 256_000)
                try:
                    message[field] = _workspace_json(value, depth=0)
                except (TypeError, ValueError):
                    # A malformed optional rich field must not hide the
                    # otherwise renderable user/assistant/tool record.
                    continue
            timestamp = row.get("timestamp")
            if (role == "assistant" and not row.get("tool_calls")
                    and isinstance(timestamp, (int, float)) and not isinstance(timestamp, bool)
                    and timestamp in unique_timestamps and timestamp in durations):
                message["turn_duration_ms"] = durations[timestamp]
            messages_by_row[index] = message

        selected: list[dict[str, Any]] = []
        consumed = 0
        selected_turns = 0
        for index in range(len(rows) - 1, -1, -1):
            message = messages_by_row.get(index)
            if message is None:
                consumed += 1
                continue
            candidate = [message, *selected]
            candidate_response = {
                "storedId": stored_id,
                "agentId": agent_id,
                "messages": candidate,
                **runtime_fields,
                "nextOffset": offset + consumed + 1,
            }
            encoded = json.dumps(
                candidate_response,
                ensure_ascii=False,
                separators=(",", ":"),
                sort_keys=True,
            ).encode("utf-8")
            if len(encoded) > _SESSION_HISTORY_RESPONSE_MAX_BYTES:
                if not selected:
                    consumed += 1
                    continue
                break
            selected = candidate
            consumed += 1
            if message["role"] == "user":
                selected_turns += 1
                if turn_limit is not None and selected_turns >= turn_limit:
                    break

        result = {
            "storedId": stored_id,
            "agentId": agent_id,
            "messages": selected,
            **runtime_fields,
        }
        if consumed < len(rows) or len(rows) == 500:
            result["nextOffset"] = offset + consumed
        return result

    async def attachments_resolve(self, payload: dict[str, Any]) -> dict[str, Any]:
        values = _object(payload, "workspace payload")
        if set(values) != {"agentId", "storedId", "items"}:
            raise WorkspaceControlError("Attachment resolve payload is invalid")
        agent_id = _agent_id(values.get("agentId"))
        stored_id = _coordinate(values.get("storedId"), 160)
        raw_items = values.get("items")
        if not isinstance(raw_items, list) or not 1 <= len(raw_items) <= 200:
            raise WorkspaceControlError("Attachment resolve payload is invalid")
        items: list[dict[str, str]] = []
        for value in raw_items:
            item = _object(value, "attachment item")
            if set(item) != {"itemId", "text"}:
                raise WorkspaceControlError("Attachment resolve payload is invalid")
            text = item.get("text")
            if not isinstance(text, str) or len(text.encode("utf-8")) > 100_000:
                raise WorkspaceControlError("Attachment resolve payload is invalid")
            items.append({"id": _coordinate(item.get("itemId"), 200), "text": text})
        resolved = await asyncio.to_thread(
            self.attachment_store.resolve,
            profile=agent_id,
            session_id=stored_id,
            items=items,
        )
        projected = []
        for item in resolved:
            attachments = [
                {
                    "id": attachment["id"],
                    "fileName": attachment["name"],
                    "mimeType": attachment["mime_type"],
                    "byteCount": attachment["size"],
                }
                for attachment in item["attachments"]
                if 0 < attachment["size"] <= MAX_AGENT_ATTACHMENT_BYTES
            ]
            projected.append({
                "itemId": item["id"],
                "text": item["text"],
                "attachments": attachments,
            })
        return {"items": projected}

    async def attachments_fetch(self, payload: dict[str, Any]) -> dict[str, Any]:
        values = _object(payload, "workspace payload")
        if set(values) != {"agentId", "attachmentId", "offset"}:
            raise WorkspaceControlError("Attachment fetch payload is invalid")
        agent_id = _agent_id(values.get("agentId"))
        attachment_id = _coordinate(values.get("attachmentId"), 128)
        offset = _nonnegative_integer(
            values.get("offset"), maximum=MAX_AGENT_ATTACHMENT_BYTES
        )
        attachment = await asyncio.to_thread(
            self.attachment_store.read,
            profile=agent_id,
            attachment_id=attachment_id,
        )
        if attachment is None or not 0 < attachment["size"] <= MAX_AGENT_ATTACHMENT_BYTES:
            raise WorkspaceControlError("Attachment is unavailable")
        content = attachment["content"]
        if not isinstance(content, bytes) or len(content) != attachment["size"] or offset >= len(content):
            raise WorkspaceControlError("Attachment is unavailable")
        chunk = content[offset : offset + MAX_ATTACHMENT_CHUNK_BYTES]
        next_offset = offset + len(chunk)
        return {
            "attachmentId": attachment_id,
            "offset": offset,
            "data": base64.b64encode(chunk).decode("ascii"),
            "nextOffset": next_offset if next_offset < len(content) else None,
        }

    async def generated_media_resolve(self, payload: dict[str, Any]) -> dict[str, Any]:
        values = _object(payload, "workspace payload")
        if set(values) != {"agentId", "storedId", "turnId", "toolCallId"}:
            raise WorkspaceControlError("Generated media resolve payload is invalid")
        agent_id = _agent_id(values.get("agentId"))
        stored_id = _coordinate(values.get("storedId"), 160)
        turn_id = _coordinate(values.get("turnId"), 180)
        tool_call_id = _coordinate(values.get("toolCallId"), 180)
        raw = _object(
            await self._session_messages(
                stored_id,
                agent_id,
                include_compacted=True,
            ),
            "Hermes session history",
        )
        rows = raw.get("messages")
        # The authenticated history service owns history bounds. This operation
        # returns only one exact tool result's bounded attachment metadata, so an
        # unrelated transcript length must not disable recent media generation.
        if raw.get("session_id", stored_id) != stored_id or not isinstance(rows, list):
            raise WorkspaceControlError("Generated media history is unavailable")
        try:
            return await asyncio.to_thread(
                resolve_generated_media,
                profile=agent_id,
                stored_id=stored_id,
                turn_id=turn_id,
                tool_call_id=tool_call_id,
                rows=rows,
                attachment_store=self.attachment_store,
            )
        except ValueError as error:
            raise WorkspaceControlError(
                "Generated media is not ready",
                code="generated_media_not_ready",
            ) from error

    async def _session_catalog(self, agent_id: str | None) -> dict[str, Any]:
        from hermes_cli.web_routers.profiles import get_profiles_sessions

        return await asyncio.to_thread(
            get_profiles_sessions,
            limit=500,
            offset=0,
            min_messages=0,
            archived="exclude",
            order="recent",
            profile=agent_id or "all",
            source=None,
            sources=None,
            exclude_sources="cron",
            full=False,
        )

    async def _session_unique_final_timestamps(self, stored_id: str, agent_id: str) -> set[float]:
        def read() -> set[float]:
            from hermes_cli.web_routers.sessions import _open_session_db_for_profile

            db = _open_session_db_for_profile(agent_id, read_only=True)
            try:
                # Read the exact stored session, not a resumed successor. Include
                # inactive rows conservatively: a timestamp reused after rewind or
                # copied by compaction cannot identify a physical completion.
                counts: dict[float, int] = {}
                offset = 0
                while True:
                    rows = db.get_messages(stored_id, include_inactive=True, limit=500, offset=offset)
                    for row in rows:
                        if row.get("role") == "assistant" and not row.get("tool_calls"):
                            timestamp = row.get("timestamp")
                            if isinstance(timestamp, (int, float)) and not isinstance(timestamp, bool):
                                counts[timestamp] = counts.get(timestamp, 0) + 1
                    if len(rows) < 500:
                        break
                    offset += len(rows)
                return {timestamp for timestamp, count in counts.items() if count == 1}
            finally:
                db.close()

        try:
            return await asyncio.to_thread(read)
        except Exception:
            # Optional metadata must not hide history on older Hermes versions
            # without this read API, or when the canonical store cannot be read.
            return set()

    async def _session_messages(
        self,
        stored_id: str,
        agent_id: str,
        *,
        include_compacted: bool = True,
        offset: int = 0,
    ) -> dict[str, Any]:
        from hermes_cli.web_routers.sessions import get_session_messages

        return await get_session_messages(
            stored_id,
            profile=agent_id,
            limit=500,
            offset=offset,
            order="latest",
            include_compacted=include_compacted,
        )

    async def _session_detail(self, session_id: str, agent_id: str) -> dict[str, Any]:
        from hermes_cli.web_routers.sessions import get_session_detail

        return await get_session_detail(session_id, profile=agent_id)

    async def _session_update(self, session_id: str, body: dict[str, Any]) -> dict[str, Any]:
        from hermes_cli.web_models import SessionRename
        from hermes_cli.web_routers.sessions import rename_session_endpoint

        return await rename_session_endpoint(session_id, SessionRename(**body))

    async def _session_delete(self, session_id: str, agent_id: str) -> dict[str, Any]:
        from hermes_cli.web_routers.sessions import delete_session_endpoint

        return await delete_session_endpoint(session_id, profile=agent_id)
