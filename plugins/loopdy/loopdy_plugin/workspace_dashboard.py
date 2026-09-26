"""Notification dashboard, completion enrichment and request-bound attention controls."""

from __future__ import annotations

import asyncio
import json
import re
from typing import Any
from .generative_ui import GenerativeUIError, validate_rendered_envelope
from .workspace_common import (
    WorkspaceConflictError,
    WorkspaceControlError,
    _agent_id,
    _coordinate,
    _coordinate_list,
    _nonnegative_integer,
    _object,
    _optional_coordinate,
    _optional_object,
    _text,
    _timestamp,
    _utf8_prefix,
)


_CRON_SESSION = re.compile(r"^cron_(.+)_\d{8}_\d{6}$")

_EVENT_DETAIL_KEYS = frozenset(
    {
        "description",
        "summary",
        "title",
        "task_title",
        "job_title",
        "message",
        "question",
        "agent_name",
        "surface",
        "pattern_key",
        "request_id",
        "kind",
        "expires_at",
        "detail",
    }
)

_COMPLETION_EVENT_TYPES = frozenset({"job.completed", "job.failed"})

_COMPLETION_SUMMARY_MAX_BYTES = 2_000


def _event_projection(
    value: Any,
    *,
    detail_maximum: int = 4_096,
    truncate_detail: bool = False,
) -> dict[str, Any]:
    source = _object(value, "Loopdy event")
    detail_source = _optional_object(source.get("detail"))
    detail: dict[str, Any] = {}
    for key in sorted(_EVENT_DETAIL_KEYS):
        raw = detail_source.get(key)
        if isinstance(raw, str):
            normalized = raw.strip()
            if normalized:
                if truncate_detail:
                    normalized = _utf8_prefix(normalized, detail_maximum)
                detail[key] = _text(normalized, detail_maximum)
    # Keep the v1 envelope unchanged while carrying exact run coordinates in
    # scalar detail fields. Stored top-level IDs are authoritative for legacy
    # cron/delegation records; never shorten or repair an identity for display.
    for key in (
        "child_session_id", "parent_session_id", "delegation_id",
        "turn_id", "job_id", "task_id",
    ):
        raw = source.get(key) if key in {"delegation_id", "job_id", "task_id"} else None
        if raw in (None, ""):
            raw = detail_source.get(key)
        if not isinstance(raw, str) or not raw or raw != raw.strip():
            continue
        try:
            detail[key] = _coordinate(raw, 180)
        except WorkspaceControlError:
            # Invalid optional metadata must not hide the underlying event.
            continue
    rendered = detail_source.get("generative_ui")
    if rendered is not None:
        try:
            detail["generative_ui"] = validate_rendered_envelope(rendered)
        except (GenerativeUIError, TypeError, ValueError):
            # A malformed optional card must not hide an otherwise useful
            # Inbox event. Native clients receive only renderer-validated
            # content; the invalid object remains private to the host store.
            pass
    interaction = detail_source.get("interaction")
    if interaction is not None:
        try:
            detail["interaction"] = _interaction_projection(interaction)
        except (TypeError, ValueError, WorkspaceControlError):
            # A malformed optional interaction must not hide the event.
            pass
    return {
        "eventId": _coordinate(source.get("event_id"), 220),
        "type": _coordinate(source.get("type"), 80),
        "profile": _agent_id(source.get("profile")),
        "sessionId": _optional_coordinate(source.get("session_id"), 180),
        "approvalId": _optional_coordinate(source.get("approval_id"), 180),
        "detail": detail,
        "createdAt": _timestamp(source.get("created_at")),
        "isRead": source.get("is_read") is True,
        "isPinned": source.get("is_pinned") is True,
    }


def _clarify_interaction_projection(value: Any) -> dict[str, Any]:
    source = _object(value, "Loopdy interaction")
    if set(source) != {
        "schemaVersion",
        "type",
        "requestId",
        "expiresAt",
        "allowsCustomResponse",
        "questions",
    }:
        raise WorkspaceControlError("Loopdy interaction is invalid")
    if source.get("schemaVersion") != 1 or source.get("type") != "clarify":
        raise WorkspaceControlError("Loopdy interaction is invalid")
    request_id = _coordinate(source.get("requestId"), 180)
    expires_at = source.get("expiresAt")
    if expires_at is not None:
        expires_at = _timestamp(expires_at)
    if source.get("allowsCustomResponse") is not True:
        raise WorkspaceControlError("Loopdy interaction is invalid")
    raw_questions = source.get("questions")
    if not isinstance(raw_questions, list) or not 1 <= len(raw_questions) <= 5:
        raise WorkspaceControlError("Loopdy interaction is invalid")
    questions = []
    for index, raw_question in enumerate(raw_questions):
        question = _object(raw_question, "Loopdy clarification question")
        if set(question) != {
            "id",
            "question",
            "choices",
            "multiSelect",
            "allowsCustomResponse",
        }:
            raise WorkspaceControlError("Loopdy interaction is invalid")
        choices = question.get("choices")
        if not isinstance(choices, list) or len(choices) > 4:
            raise WorkspaceControlError("Loopdy interaction is invalid")
        projected_choices = [_text(choice, 500) for choice in choices]
        if any(not choice for choice in projected_choices):
            raise WorkspaceControlError("Loopdy interaction is invalid")
        projected = {
            "id": _coordinate(question.get("id") or f"q{index}", 80),
            "question": _text(question.get("question"), 2_000),
            "choices": projected_choices,
            "multiSelect": question.get("multiSelect") is True,
            "allowsCustomResponse": question.get("allowsCustomResponse") is True,
        }
        if not projected["question"] or not projected["allowsCustomResponse"]:
            raise WorkspaceControlError("Loopdy interaction is invalid")
        questions.append(projected)
    return {
        "schemaVersion": 1,
        "type": "clarify",
        "requestId": request_id,
        "expiresAt": expires_at,
        "allowsCustomResponse": True,
        "questions": questions,
    }


def _approval_interaction_projection(value: Any) -> dict[str, Any]:
    source = _object(value, "Loopdy interaction")
    if set(source) != {
        "schemaVersion",
        "type",
        "requestId",
        "expiresAt",
        "allowedChoices",
    }:
        raise WorkspaceControlError("Loopdy interaction is invalid")
    if source.get("schemaVersion") != 1 or source.get("type") != "approval":
        raise WorkspaceControlError("Loopdy interaction is invalid")
    choices = _coordinate_list(
        source.get("allowedChoices"), maximum=4, item_maximum=16
    )
    if not set(choices).issubset({"once", "session", "always", "deny"}):
        raise WorkspaceControlError("Loopdy interaction is invalid")
    return {
        "schemaVersion": 1,
        "type": "approval",
        "requestId": _coordinate(source.get("requestId"), 180),
        "expiresAt": _timestamp(source.get("expiresAt")),
        "allowedChoices": choices,
    }


def _interaction_projection(value: Any) -> dict[str, Any]:
    source = _object(value, "Loopdy interaction")
    if source.get("type") == "clarify":
        return _clarify_interaction_projection(source)
    if source.get("type") == "approval":
        return _approval_interaction_projection(source)
    raise WorkspaceControlError("Loopdy interaction is invalid")


def _event_projection_v2(
    value: Any,
    *,
    detail_maximum: int = 4_096,
    truncate_detail: bool = False,
) -> dict[str, Any]:
    projected = _event_projection(
        value,
        detail_maximum=detail_maximum,
        truncate_detail=truncate_detail,
    )
    source = _object(value, "Loopdy event")
    if source.get("type") in _COMPLETION_EVENT_TYPES:
        projected["taskId"] = _optional_coordinate(
            source.get("task_id"), 180
        ) or _coordinate(source.get("job_id"), 180)
        detail = _object(projected["detail"], "Loopdy event detail")
        status = _optional_object(source.get("detail")).get("status")
        if status not in {"completed", "failed"}:
            raise WorkspaceControlError("Loopdy completion status is invalid")
        detail["status"] = status
    return projected


def _completion_catalog(value: Any, *, profile: str) -> dict[str, str]:
    if not isinstance(value, list) or len(value) > 500:
        raise WorkspaceControlError("Hermes scheduled task catalog is invalid")
    catalog: dict[str, str] = {}
    for item in value:
        source = _object(item, "Hermes scheduled task")
        item_profile = source.get("profile")
        if item_profile not in {None, ""} and _agent_id(item_profile) != profile:
            raise WorkspaceControlError("Hermes scheduled task profile is invalid")
        task_id = _optional_coordinate(source.get("id"), 180) or _coordinate(
            source.get("job_id"), 180
        )
        name = _text(source.get("name"), 240)
        if task_id in catalog:
            raise WorkspaceControlError("Hermes scheduled task identity is ambiguous")
        catalog[task_id] = name
    return catalog


def _cron_job_id(session_id: str) -> str:
    match = _CRON_SESSION.fullmatch(session_id)
    return match.group(1) if match else ""


def _final_assistant_result(value: dict[str, Any]) -> str:
    rows = value.get("messages")
    if not isinstance(rows, list) or not rows or len(rows) > 500:
        raise WorkspaceControlError("Hermes session history is invalid")
    final = _object(rows[-1], "Hermes final assistant result")
    if final.get("role") != "assistant":
        raise WorkspaceControlError("Hermes final assistant result is unavailable")
    display_content = final.get("display_content")
    if isinstance(display_content, str) and display_content != "":
        content = _text(display_content, 1_000_000)
    else:
        requires_display_projection = (
            final.get("display_kind") == "hidden"
            or final.get("_compressed_summary") is True
            or final.get("compacted") is True
        )
        if requires_display_projection:
            raise WorkspaceControlError("Hermes final assistant result is unavailable")
        content = _text(final.get("content"), 1_000_000)
    summary = _utf8_prefix(content, _COMPLETION_SUMMARY_MAX_BYTES)
    if not summary:
        raise WorkspaceControlError("Hermes final assistant result is unavailable")
    return summary


def _approval_projection(value: Any, *, now: int) -> dict[str, Any]:
    source = _object(value, "Loopdy approval")
    status = _coordinate(source.get("status"), 32)
    expires_at = _timestamp(source.get("expires_at"))
    choices = _coordinate_list(
        source.get("allowed_choices"), maximum=4, item_maximum=16
    )
    if status != "pending" or expires_at <= now:
        raise WorkspaceConflictError("Approval is no longer pending")
    if not set(choices).issubset({"once", "session", "always", "deny"}):
        raise WorkspaceControlError("Approval choices are invalid")
    return {
        "id": _coordinate(source.get("approval_id"), 180),
        "requestDigest": _coordinate(source.get("request_digest"), 180),
        "eventId": _coordinate(source.get("event_id"), 220),
        "status": status,
        "allowedChoices": choices,
        "expiresAt": expires_at,
    }


_DASHBOARD_EVENT_LIMIT = 200

_DASHBOARD_RESPONSE_MAX_BYTES = 160_000

_DASHBOARD_DETAIL_MAX_BYTES = 40_000


class DashboardControls:
    async def dashboard_load(self, payload: dict[str, Any]) -> dict[str, Any]:
        if payload == {}:
            schema_version = 1
        elif (
            isinstance(payload, dict)
            and set(payload) == {"schemaVersion"}
            and type(payload.get("schemaVersion")) is int
            and payload["schemaVersion"] == 2
        ):
            schema_version = 2
        else:
            raise WorkspaceControlError("Dashboard payload is invalid")
        await asyncio.to_thread(self._clean_dashboard_events)
        if schema_version == 1:
            events = await asyncio.to_thread(self._dashboard_events)
            return {"events": events}
        events = await self._dashboard_events_v2()
        return {"schemaVersion": 2, "events": events}

    async def dashboard_set_event_state(self, payload: dict[str, Any]) -> dict[str, Any]:
        values = _object(payload, "workspace payload")
        if set(values) != {"eventId", "isRead", "isPinned"}:
            raise WorkspaceControlError("Dashboard event state payload is invalid")
        event_id = _coordinate(values.get("eventId"), 220)
        is_read = values.get("isRead")
        is_pinned = values.get("isPinned")
        if type(is_read) is not bool or type(is_pinned) is not bool:
            raise WorkspaceControlError("Dashboard event state payload is invalid")
        changed = await asyncio.to_thread(
            self.service.store.set_event_state,
            event_id,
            is_read=is_read,
            is_pinned=is_pinned,
        )
        if not changed:
            raise WorkspaceConflictError("Dashboard event is no longer available")
        return {"eventId": event_id, "isRead": is_read, "isPinned": is_pinned}

    async def dashboard_dismiss_event(self, payload: dict[str, Any]) -> dict[str, Any]:
        values = _object(payload, "workspace payload")
        if set(values) != {"eventId"}:
            raise WorkspaceControlError("Dashboard event payload is invalid")
        event_id = _coordinate(values.get("eventId"), 220)
        dismissed = await asyncio.to_thread(self.service.store.dismiss_event, event_id)
        if not dismissed:
            raise WorkspaceConflictError("Dashboard event is no longer available")
        return {"eventId": event_id, "dismissed": True}

    async def dashboard_dismiss_events(self, payload: dict[str, Any]) -> dict[str, Any]:
        values = _object(payload, "workspace payload")
        if values == {"all": True}:
            rows = await asyncio.to_thread(self._all_events)
            ids = [_coordinate(row.get("event_id"), 220) for row in rows]
            return {"dismissed": await self._dismiss_event_ids(ids)}
        allowed = {"eventIds", "eventTypes", "createdBefore"}
        if not values or set(values) - allowed:
            raise WorkspaceControlError("Dashboard dismissal payload is invalid")
        has_ids = "eventIds" in values
        has_types = "eventTypes" in values
        if has_ids == has_types:
            raise WorkspaceControlError("Choose event IDs or event types")
        cutoff = (
            _timestamp(values.get("createdBefore"))
            if "createdBefore" in values
            else None
        )
        if has_ids:
            ids = _coordinate_list(values.get("eventIds"), maximum=2_000, item_maximum=220)
            return {"dismissed": await self._dismiss_event_ids(ids, created_before=cutoff)}
        event_types = _coordinate_list(
            values.get("eventTypes"), maximum=32, item_maximum=80
        )
        dismissed = await asyncio.to_thread(
            self.service.store.dismiss_events,
            event_types=event_types,
            created_before=cutoff,
        )
        return {"dismissed": _nonnegative_integer(dismissed, maximum=10_000_000)}

    async def approvals_load(self, payload: dict[str, Any]) -> dict[str, Any]:
        values = _object(payload, "workspace payload")
        if set(values) != {"approvalId"}:
            raise WorkspaceControlError("Approval payload is invalid")
        approval_id = _coordinate(values.get("approvalId"), 180)
        approval = await asyncio.to_thread(self.service.store.get_approval, approval_id)
        projected = _approval_projection(approval, now=int(self.clock()))
        event = await asyncio.to_thread(
            self.service.store.get_event, projected["eventId"]
        )
        projected_event = _event_projection(event)
        if (
            projected_event["type"] != "approval.required"
            or projected_event["approvalId"] != approval_id
        ):
            raise WorkspaceConflictError("Approval event changed")
        return {"approval": projected, "event": projected_event}

    async def approvals_respond(self, payload: dict[str, Any]) -> dict[str, Any]:
        values = _object(payload, "workspace payload")
        if set(values) != {"approvalId", "requestDigest", "choice"}:
            raise WorkspaceControlError("Approval response payload is invalid")
        approval_id = _coordinate(values.get("approvalId"), 180)
        digest = _coordinate(values.get("requestDigest"), 180)
        choice = _coordinate(values.get("choice"), 16)
        if choice not in {"once", "session", "always", "deny"}:
            raise WorkspaceControlError("Approval choice is invalid")
        approval = await asyncio.to_thread(self.service.store.get_approval, approval_id)
        projected = _approval_projection(approval, now=int(self.clock()))
        if projected["requestDigest"] != digest or choice not in projected["allowedChoices"]:
            raise WorkspaceConflictError("Approval request changed")
        accepted = await asyncio.to_thread(
            self.service.store.respond_approval, approval_id, choice
        )
        if not accepted:
            raise WorkspaceConflictError("Approval is expired or already answered")
        return {"accepted": True, "approvalId": approval_id, "choice": choice}

    async def clarifications_respond(self, payload: dict[str, Any]) -> dict[str, Any]:
        values = _object(payload, "workspace payload")
        if set(values) != {"eventId", "clarifyId", "response"}:
            raise WorkspaceControlError("Clarification response payload is invalid")
        event_id = _coordinate(values.get("eventId"), 220)
        clarify_id = _coordinate(values.get("clarifyId"), 180)
        response = _text(values.get("response"), 16_000)
        if not response:
            raise WorkspaceControlError("Clarification response is invalid")

        event = await asyncio.to_thread(self.service.store.get_event, event_id)
        source = _object(event, "Loopdy clarification event")
        detail = _object(source.get("detail"), "Loopdy clarification detail")
        if (
            source.get("dismissed_at") is not None
            or source.get("type") != "attention.required"
            or detail.get("kind") != "clarify"
            or detail.get("request_id") != clarify_id
        ):
            raise WorkspaceConflictError("Clarification request changed")
        try:
            interaction = _clarify_interaction_projection(detail.get("interaction"))
        except (TypeError, ValueError, WorkspaceControlError) as error:
            raise WorkspaceConflictError("Clarification request changed") from error
        if interaction["requestId"] != clarify_id:
            raise WorkspaceConflictError("Clarification request changed")
        session_key = _coordinate(
            detail.get("session_key") or source.get("session_id"),
            180,
        )
        raw_expiry = detail.get("expires_at")
        scalar_expiry = _timestamp(raw_expiry) if raw_expiry is not None else None
        if scalar_expiry != interaction["expiresAt"]:
            raise WorkspaceConflictError("Clarification request changed")
        if scalar_expiry is not None and scalar_expiry <= int(self.clock()):
            raise WorkspaceConflictError("Clarification request expired")

        from tools.clarify_gateway import (
            get_pending_for_session,
            resolve_gateway_clarify,
        )

        pending = await asyncio.to_thread(
            get_pending_for_session,
            session_key,
            include_choice_prompts=True,
        )
        if (
            pending is None
            or str(getattr(pending, "clarify_id", "")) != clarify_id
        ):
            raise WorkspaceConflictError("Clarification is no longer pending")
        accepted = await asyncio.to_thread(
            resolve_gateway_clarify,
            clarify_id,
            response,
        )
        if not accepted:
            raise WorkspaceConflictError("Clarification is no longer pending")
        await asyncio.to_thread(self.service.store.dismiss_event, event_id)
        return {
            "accepted": True,
            "eventId": event_id,
            "clarifyId": clarify_id,
        }

    def _clean_dashboard_events(self) -> None:
        now = int(self.clock())
        store = self.service.store
        store.dismiss_gateway_lifecycle_events(dismissed_at=now)
        store.dismiss_inactive_approval_events(now=now, dismissed_at=now)
        try:
            if self.clarify_timeout is not None:
                clarify_timeout = int(self.clarify_timeout())
            else:
                from tools.clarify_gateway import get_clarify_timeout

                clarify_timeout = int(get_clarify_timeout())
        except (ImportError, TypeError, ValueError):
            clarify_timeout = 3_600
        if clarify_timeout > 0:
            store.dismiss_expired_attention(
                now - clarify_timeout,
                dismissed_at=now,
            )

    def _all_events(self, *, maximum: int = 2_000) -> list[dict[str, Any]]:
        events: list[dict[str, Any]] = []
        offset = 0
        while offset < maximum:
            page_limit = min(200, maximum - offset)
            page = self.service.store.list_events(limit=page_limit, offset=offset)
            if not isinstance(page, list) or len(page) > 200:
                raise WorkspaceControlError("Loopdy event catalog is invalid")
            events.extend(page)
            if len(page) < page_limit:
                break
            offset += len(page)
        return events

    def _dashboard_events(self) -> list[dict[str, Any]]:
        """Return a recent, transport-sized event projection source.

        A dashboard response is sent in one encrypted Loopdy Link frame. A
        full event catalog can exceed that frame even though each individual
        event is valid, so keep this summary bounded and let session history
        provide the complete detail path.
        """
        rows = self._all_events(maximum=_DASHBOARD_EVENT_LIMIT)
        selected: list[dict[str, Any]] = []
        for row in rows:
            projected = _event_projection(
                row,
                detail_maximum=_DASHBOARD_DETAIL_MAX_BYTES,
                truncate_detail=True,
            )
            candidate = selected + [projected]
            encoded = json.dumps(
                {"events": candidate},
                separators=(",", ":"),
                ensure_ascii=True,
            ).encode("utf-8")
            if len(encoded) > _DASHBOARD_RESPONSE_MAX_BYTES:
                break
            selected.append(projected)
        return selected

    async def _dashboard_events_v2(self) -> list[dict[str, Any]]:
        rows = await asyncio.to_thread(
            self._all_events,
            maximum=_DASHBOARD_EVENT_LIMIT,
        )
        enriched = await self.enrich_completion_events(
            rows,
            preserve_unenriched=False,
        )
        selected: list[dict[str, Any]] = []
        for row in enriched:
            try:
                projected = _event_projection_v2(
                    row,
                    detail_maximum=_DASHBOARD_DETAIL_MAX_BYTES,
                    truncate_detail=True,
                )
            except (TypeError, ValueError, WorkspaceControlError):
                if isinstance(row, dict) and row.get("type") in _COMPLETION_EVENT_TYPES:
                    continue
                raise
            candidate = selected + [projected]
            encoded = json.dumps(
                {"schemaVersion": 2, "events": candidate},
                separators=(",", ":"),
                ensure_ascii=True,
            ).encode("utf-8")
            if len(encoded) > _DASHBOARD_RESPONSE_MAX_BYTES:
                break
            selected.append(projected)
        return selected

    async def enrich_completion_events(
        self,
        rows: list[dict[str, Any]],
        *,
        preserve_unenriched: bool = True,
    ) -> list[dict[str, Any]]:
        """Resolve completion metadata without dropping durable REST events."""
        if not isinstance(rows, list) or len(rows) > _DASHBOARD_EVENT_LIMIT:
            raise WorkspaceControlError("Loopdy event catalog is invalid")
        catalogs: dict[str, dict[str, str] | None] = {}
        for row in rows:
            if not isinstance(row, dict) or row.get("type") not in _COMPLETION_EVENT_TYPES:
                continue
            try:
                profile = _agent_id(row.get("profile"))
            except (TypeError, ValueError, WorkspaceControlError):
                continue
            if profile in catalogs:
                continue
            try:
                catalogs[profile] = _completion_catalog(
                    await self._cron_list(profile),
                    profile=profile,
                )
            except Exception:
                catalogs[profile] = None

        enriched: list[dict[str, Any]] = []
        for row in rows:
            if not isinstance(row, dict) or row.get("type") not in _COMPLETION_EVENT_TYPES:
                enriched.append(row)
                continue
            try:
                profile = _agent_id(row.get("profile"))
                session_id = _coordinate(row.get("session_id"), 180)
                task_id = await self._canonical_cron_job_id(
                    session_id,
                    profile,
                )
                catalog = catalogs.get(profile)
                if catalog is None or task_id not in catalog:
                    if preserve_unenriched:
                        enriched.append(row)
                    continue
                history = _object(
                    await self._session_messages(
                        session_id,
                        profile,
                        include_compacted=True,
                    ),
                    "Hermes session history",
                )
                detail = dict(_optional_object(row.get("detail")))
                detail.update(
                    {
                        "title": catalog[task_id],
                        "summary": _final_assistant_result(history),
                        "status": (
                            "completed"
                            if row.get("type") == "job.completed"
                            else "failed"
                        ),
                    }
                )
                enriched.append(
                    {
                        **row,
                        "job_id": task_id,
                        "task_id": task_id,
                        "detail": detail,
                    }
                )
            except Exception:
                # The durable REST event remains useful even when current host
                # catalogs cannot prove richer completion metadata. Link
                # Dashboard v2 opts out to avoid generic scheduled-task rows.
                if preserve_unenriched:
                    enriched.append(row)
                continue
        return enriched

    async def _canonical_cron_job_id(self, session_id: str, agent_id: str) -> str:
        """Resolve only cron-owned identity through verified compression edges."""
        direct = _cron_job_id(session_id)
        if direct:
            return direct

        current = session_id
        visited: set[str] = set()
        for _ in range(32):
            if current in visited:
                break
            visited.add(current)
            child = _object(
                await self._session_detail(current, agent_id),
                "Hermes session detail",
            )
            if _coordinate(child.get("id"), 180) != current:
                break
            parent_id = _optional_coordinate(child.get("parent_session_id"), 180)
            if parent_id is None or parent_id in visited:
                break
            parent = _object(
                await self._session_detail(parent_id, agent_id),
                "Hermes parent session detail",
            )
            child_source = _coordinate(child.get("source"), 80)
            parent_source = _coordinate(parent.get("source"), 80)
            child_model = _optional_object(child.get("model_config"))
            if (
                _coordinate(parent.get("id"), 180) != parent_id
                or child_source != "cron"
                or parent_source != child_source
                or any(
                    child_model.get(marker) is not None
                    for marker in ("_branched_from", "_delegate_from", "_reset_from")
                )
                or parent.get("end_reason") != "compression"
                or _timestamp(child.get("started_at"))
                < _timestamp(parent.get("ended_at"))
            ):
                break
            canonical = _cron_job_id(parent_id)
            if canonical:
                return canonical
            current = parent_id
        raise WorkspaceControlError("Hermes cron session identity is unavailable")

    async def _dismiss_event_ids(
        self, ids: list[str], *, created_before: int | None = None
    ) -> int:
        dismissed = 0
        for start in range(0, len(ids), 200):
            count = await asyncio.to_thread(
                self.service.store.dismiss_events,
                event_ids=ids[start : start + 200],
                created_before=created_before,
            )
            dismissed += _nonnegative_integer(count, maximum=10_000_000)
        return dismissed
