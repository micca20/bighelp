"""Live hook projections, generative UI events and form-submission contracts."""
from __future__ import annotations

import math
import re
import uuid
from dataclasses import dataclass
from typing import Any

from .events import EVENT_TYPES
from .generative_ui import canonical_json, validate_rendered_envelope
from .protocol_values import (
    _activity_detail, _activity_label, _label, _nonnegative, _opaque,
    _picker_identifier, _positive, _session_coordinate, _text, _validate_envelope,
)

STATE_BACKED_PRESENTATION_CAPABILITY = "state-backed-presentation-v1"


def is_transient_presentation(payload: dict[str, Any]) -> bool:
    """Only negotiated replaceable presentation, never reliable settlement."""
    kind = payload.get("type")
    if kind == "assistant.message":
        return payload.get("delivery") == "draft"
    return kind in {"activity.event", "session.context", "session.todos",
                    "session.subagents", "generative.ui"}


@dataclass(frozen=True)
class GenerativeUIFormSubmission:
    request_id: str
    session_id: str
    profile: str
    idempotency_key: str
    values: dict[str, Any]
    submitted_at: int

    def wire_value(self) -> dict[str, Any]:
        return {
            "version": 1,
            "type": "generative.ui.form.submit",
            "requestId": self.request_id,
            "sessionId": self.session_id,
            "profile": self.profile,
            "idempotencyKey": self.idempotency_key,
            "values": dict(self.values),
            "submittedAt": self.submitted_at,
        }


def parse_generative_ui_form_submission(
    value: dict[str, Any],
) -> GenerativeUIFormSubmission:
    expected = {
        "version", "type", "requestId", "sessionId", "profile",
        "idempotencyKey", "values", "submittedAt",
    }
    _validate_envelope(
        value, expected, "generative.ui.form.submit", "Loopdy Link form submission is invalid",
        strict_version=False,
    )
    request_id = str(value.get("requestId") or "")
    if not re.fullmatch(r"[0-9a-f]{32}", request_id):
        raise ValueError("Loopdy Link form requestId is invalid")
    idempotency_key = str(value.get("idempotencyKey") or "")
    try:
        parsed_key = uuid.UUID(idempotency_key)
    except (ValueError, AttributeError) as exc:
        raise ValueError("Loopdy Link form idempotencyKey is invalid") from exc
    if str(parsed_key) != idempotency_key:
        raise ValueError("Loopdy Link form idempotencyKey is invalid")
    values = _form_submission_values(value.get("values"))
    return GenerativeUIFormSubmission(
        request_id=request_id,
        session_id=_session_coordinate(value.get("sessionId")),
        profile=_opaque(value.get("profile"), "profile", 1, 80),
        idempotency_key=idempotency_key,
        values=values,
        submitted_at=_positive(value.get("submittedAt"), "submittedAt"),
    )


def assistant_message(
    *,
    message_id: str,
    session_id: str,
    text: str,
    sent_at: int,
    agent_name: str,
    agent_id: str,
    delivery: str = "final",
    draft_id: int | None = None,
) -> dict[str, Any]:
    if delivery not in {"draft", "final"}:
        raise ValueError("Loopdy Link assistant delivery is invalid")
    value: dict[str, Any] = {
        "version": 1,
        "type": "assistant.message",
        "messageId": _opaque(message_id, "messageId", 16, 128),
        "sessionId": _session_coordinate(session_id),
        "agentId": _opaque(agent_id, "agentId", 1, 96),
        "agentName": _label(agent_name, "agentName", 80),
        "text": _text(text, "text", 100_000),
        "sentAt": _positive(sent_at, "sentAt"),
        "delivery": delivery,
    }
    if draft_id is not None:
        value["draftId"] = _positive(draft_id, "draftId")
    return value


def notification_event(
    *,
    event_id: str,
    event_type: str,
    agent_id: str,
    agent_name: str,
    session_id: str,
    title: str,
    body: str,
    sent_at: int,
    card: dict[str, Any] | None = None,
) -> dict[str, Any]:
    if event_type not in EVENT_TYPES:
        raise ValueError("Loopdy Link notification event type is invalid")
    value: dict[str, Any] = {
        "version": 1,
        "type": "notification.event",
        "eventId": _picker_identifier(event_id, "eventId", 1, 220),
        "eventType": event_type,
        "agentId": _opaque(agent_id, "agentId", 1, 96),
        "agentName": _label(agent_name, "agentName", 80),
        "title": _activity_label(title, "title", 100),
        "body": _activity_label(body, "body", 800),
        "sentAt": _positive(sent_at, "sentAt"),
    }
    if session_id:
        value["sessionId"] = _session_coordinate(session_id)
    if card is not None:
        value["card"] = validate_rendered_envelope(card)
    return value


def activity_event(
    *,
    event_id: str,
    session_id: str,
    turn_id: str,
    kind: str,
    lifecycle: str,
    title: str,
    summary: str | None,
    detail: str | None,
    occurred_at: int,
    arguments: str | None = None,
    result: str | None = None,
    duration_ms: int | None = None,
    tool_call_id: str | None = None,
    tool_name: str | None = None,
    subagent_id: str | None = None,
    bot_run_id: str | None = None,
    member_id: str | None = None,
    from_member_id: str | None = None,
) -> dict[str, Any]:
    if kind not in {"reasoning", "tool", "subagent", "bot_handoff"}:
        raise ValueError("Loopdy Link activity kind is invalid")
    if lifecycle not in {"running", "succeeded", "failed", "cancelled"}:
        raise ValueError("Loopdy Link activity lifecycle is invalid")
    if kind == "reasoning":
        valid_identity = all(
            value is None
            for value in (tool_call_id, subagent_id, bot_run_id, member_id, from_member_id)
        )
    elif kind == "tool":
        valid_identity = (
            tool_call_id is not None
            and all(value is None for value in (subagent_id, bot_run_id, member_id, from_member_id))
        )
    elif kind == "subagent":
        valid_identity = (
            subagent_id is not None
            and all(value is None for value in (tool_call_id, bot_run_id, member_id, from_member_id))
        )
    else:
        valid_identity = (
            bot_run_id is not None
            and member_id is not None
            and tool_call_id is None
            and subagent_id is None
        )
    if not valid_identity:
        raise ValueError("Loopdy Link activity identity is invalid")
    if kind not in {"tool", "bot_handoff"} and (arguments is not None or result is not None):
        raise ValueError("Loopdy Link activity detail is invalid")
    if kind != "tool" and tool_name is not None:
        raise ValueError("Loopdy Link tool detail is invalid")
    value: dict[str, Any] = {
        "version": 1,
        "type": "activity.event",
        "eventId": _opaque(event_id, "eventId", 16, 128),
        "sessionId": _session_coordinate(session_id),
        "turnId": _opaque(turn_id, "turnId", 8, 180),
        "kind": kind,
        "lifecycle": lifecycle,
        "title": _activity_label(title, "title", 80),
        "occurredAt": _positive(occurred_at, "occurredAt"),
    }
    optional_labels = (("summary", summary, 500), ("detail", detail, 1_000))
    for key, candidate, maximum in optional_labels:
        if candidate is not None:
            value[key] = _activity_label(candidate, key, maximum)
    for key, candidate in (("arguments", arguments), ("result", result)):
        if candidate is not None:
            if kind == "bot_handoff" and len(candidate.encode("utf-8")) > 64_000:
                raise ValueError(f"Loopdy Link {key} is invalid")
            value[key] = _activity_detail(candidate, key, 65_536)
    if duration_ms is not None:
        duration = _nonnegative(duration_ms, "durationMs")
        if duration > 86_400_000:
            raise ValueError("Loopdy Link durationMs is invalid")
        value["durationMs"] = duration
    for key, candidate, maximum in (
        ("toolCallId", tool_call_id, 180),
        ("toolName", tool_name, 80),
        ("subagentId", subagent_id, 180),
        ("botRunId", bot_run_id, 180),
        ("memberId", member_id, 96),
        ("fromMemberId", from_member_id, 96),
    ):
        if candidate is not None:
            value[key] = _opaque(candidate, key, 1, maximum)
    return value


def session_context(
    *,
    session_id: str,
    model: str,
    context_used: int,
    context_max: int,
    context_percent: int,
    compressions: int,
    is_compacting: bool,
    updated_at: int,
    title: str | None = None,
    input_tokens: int | None = None,
    output_tokens: int | None = None,
    cached_tokens: int | None = None,
    total_tokens: int | None = None,
    session_input_tokens: int | None = None,
    session_output_tokens: int | None = None,
    session_cached_tokens: int | None = None,
    session_total_tokens: int | None = None,
    session_includes_subagents: bool | None = None,
) -> dict[str, Any]:
    """Build the encrypted current-context projection for one Link chat."""

    used = _nonnegative(context_used, "contextUsed")
    maximum = _positive(context_max, "contextMax")
    percent = _nonnegative(context_percent, "contextPercent")
    if percent > 100:
        raise ValueError("Loopdy Link contextPercent is invalid")
    if type(is_compacting) is not bool:
        raise ValueError("Loopdy Link isCompacting is invalid")
    value = {
        "version": 1,
        "type": "session.context",
        "sessionId": _session_coordinate(session_id),
        "model": _activity_label(model, "model", 160),
        "contextUsed": used,
        "contextMax": maximum,
        "contextPercent": percent,
        "compressions": _nonnegative(compressions, "compressions"),
        "isCompacting": is_compacting,
        "updatedAt": _positive(updated_at, "updatedAt"),
    }
    if title is not None:
        value["title"] = _activity_label(title, "title", 240)
    # Token accounting is additive: a Hermes runtime that cannot report a
    # metric omits its key rather than publishing a misleading zero.
    for key, candidate in (
        ("inputTokens", input_tokens),
        ("outputTokens", output_tokens),
        ("cachedTokens", cached_tokens),
        ("totalTokens", total_tokens),
        ("sessionInputTokens", session_input_tokens),
        ("sessionOutputTokens", session_output_tokens),
        ("sessionCachedTokens", session_cached_tokens),
        ("sessionTotalTokens", session_total_tokens),
    ):
        if candidate is not None:
            value[key] = _nonnegative(candidate, key)
    if session_includes_subagents is not None:
        if type(session_includes_subagents) is not bool:
            raise ValueError("Loopdy Link sessionIncludesSubagents is invalid")
        value["sessionIncludesSubagents"] = session_includes_subagents
    return value


def session_todos(
    *,
    session_id: str,
    revision: int,
    todos: list[dict[str, Any]],
    updated_at: int,
) -> dict[str, Any]:
    """Build Hermes' revisioned full todo snapshot for one encrypted chat."""

    if not isinstance(todos, list) or len(todos) > 256:
        raise ValueError("Loopdy Link todos are invalid")
    projected: list[dict[str, Any]] = []
    seen: set[str] = set()
    for raw in todos:
        if not isinstance(raw, dict) or set(raw) not in (
            {"id", "content", "status"},
            {"id", "content", "status", "parent"},
        ):
            raise ValueError("Loopdy Link todo is invalid")
        item_id = _activity_label(raw.get("id"), "todo id", 128)
        if item_id in seen:
            raise ValueError("Loopdy Link todo id is invalid")
        seen.add(item_id)
        status = raw.get("status")
        if status not in {"pending", "in_progress", "completed", "cancelled"}:
            raise ValueError("Loopdy Link todo status is invalid")
        item: dict[str, Any] = {
            "id": item_id,
            "content": _activity_detail(raw.get("content"), "todo content", 4_000),
            "status": status,
        }
        if "parent" in raw:
            parent = _activity_label(raw.get("parent"), "todo parent", 128)
            if parent == item_id:
                raise ValueError("Loopdy Link todo parent is invalid")
            item["parent"] = parent
        projected.append(item)
    return {
        "version": 1,
        "type": "session.todos",
        "sessionId": _session_coordinate(session_id),
        "revision": _nonnegative(revision, "revision"),
        "todos": projected,
        "updatedAt": _positive(updated_at, "updatedAt"),
    }


def session_subagents(
    *,
    session_id: str,
    subagents: list[dict[str, Any]],
    updated_at: int,
) -> dict[str, Any]:
    """Build the active delegated-child roster for one encrypted chat."""

    if not isinstance(subagents, list) or len(subagents) > 256:
        raise ValueError("Loopdy Link subagent roster is invalid")
    projected: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    seen_sessions: set[str] = set()
    for raw in subagents:
        if not isinstance(raw, dict) or set(raw) not in (
            {"id", "sessionId", "role", "goal", "startedAt"},
            {"id", "sessionId", "parentId", "role", "goal", "startedAt"},
        ):
            raise ValueError("Loopdy Link subagent is invalid")
        subagent_id = _opaque(raw.get("id"), "subagent id", 1, 180)
        child_session_id = _session_coordinate(
            raw.get("sessionId"), field="subagent sessionId"
        )
        if subagent_id in seen_ids or child_session_id in seen_sessions:
            raise ValueError("Loopdy Link subagent identity is invalid")
        seen_ids.add(subagent_id)
        seen_sessions.add(child_session_id)
        item: dict[str, Any] = {
            "id": subagent_id,
            "sessionId": child_session_id,
            "role": _activity_label(raw.get("role"), "subagent role", 80),
            "goal": _activity_label(raw.get("goal"), "subagent goal", 2_000),
            "startedAt": _positive(raw.get("startedAt"), "subagent startedAt"),
        }
        if "parentId" in raw:
            parent_id = _opaque(raw.get("parentId"), "subagent parentId", 1, 180)
            if parent_id == subagent_id:
                raise ValueError("Loopdy Link subagent parentId is invalid")
            item["parentId"] = parent_id
        projected.append(item)
    return {
        "version": 1,
        "type": "session.subagents",
        "sessionId": _session_coordinate(session_id),
        "subagents": projected,
        "updatedAt": _positive(updated_at, "updatedAt"),
    }


def generative_ui_event(
    *,
    event_id: str,
    session_id: str,
    turn_id: str,
    tool_call_id: str,
    agent_id: str,
    agent_name: str,
    card: dict[str, Any],
    occurred_at: int,
) -> dict[str, Any]:
    return {
        "version": 1,
        "type": "generative.ui",
        "eventId": _opaque(event_id, "eventId", 16, 128),
        "sessionId": _session_coordinate(session_id),
        "turnId": _opaque(turn_id, "turnId", 8, 180),
        "toolCallId": _opaque(tool_call_id, "toolCallId", 1, 180),
        "agentId": _opaque(agent_id, "agentId", 1, 96),
        "agentName": _label(agent_name, "agentName", 80),
        "card": validate_rendered_envelope(card),
        "occurredAt": _positive(occurred_at, "occurredAt"),
    }


def generative_ui_form_result(
    *,
    request: GenerativeUIFormSubmission,
    state: str,
    code: str,
    message: str,
    sent_at: int,
) -> dict[str, Any]:
    if state not in {"success", "error"}:
        raise ValueError("Loopdy Link form result state is invalid")
    allowed_codes = {
        "accepted", "request_not_found", "request_expired", "owner_mismatch",
        "invalid_value", "already_submitted", "already_consumed",
        "idempotency_conflict", "payload_too_large", "internal_error",
    }
    if code not in allowed_codes:
        raise ValueError("Loopdy Link form result code is invalid")
    return {
        "version": 1,
        "type": "generative.ui.form.result",
        "requestId": request.request_id,
        "sessionId": request.session_id,
        "idempotencyKey": request.idempotency_key,
        "state": state,
        "code": code,
        "message": _activity_label(message, "message", 160),
        "sentAt": _positive(sent_at, "sentAt"),
    }


def _form_submission_values(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict) or len(value) > 12:
        raise ValueError("Loopdy Link form values are invalid")
    if len(canonical_json(value).encode("utf-8")) > 8_192:
        raise ValueError("Loopdy Link form values are invalid")
    for key, candidate in value.items():
        if not isinstance(key, str) or not re.fullmatch(r"[a-z][a-z0-9_-]{0,39}", key):
            raise ValueError("Loopdy Link form value key is invalid")
        values = candidate if isinstance(candidate, list) else [candidate]
        if len(values) > 10:
            raise ValueError("Loopdy Link form values are invalid")
        for item in values:
            if item is None or isinstance(item, (dict, list)):
                raise ValueError("Loopdy Link form values are invalid")
            if isinstance(item, str) and (len(item) > 2_000 or "\x00" in item):
                raise ValueError("Loopdy Link form values are invalid")
            if isinstance(item, (int, float)) and not isinstance(item, bool):
                if not math.isfinite(float(item)) or abs(float(item)) > 1_000_000_000_000:
                    raise ValueError("Loopdy Link form values are invalid")
            elif not isinstance(item, (str, bool)):
                raise ValueError("Loopdy Link form values are invalid")
    return dict(value)
