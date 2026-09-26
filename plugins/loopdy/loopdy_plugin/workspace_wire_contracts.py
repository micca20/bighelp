"""Workspace requests, results and operation-specific payload policies."""
from __future__ import annotations

import base64
import json
import math
import re
from dataclasses import dataclass
from typing import Any

from .generative_ui import validate_rendered_envelope
from .groups_contracts import (
    GROUPS_RESULT_PAYLOAD_BYTES, GROUPS_RESULT_ENVELOPE_BYTES, GROUPS_RESULTS_CAPABILITY,
    validate_log_page, validate_result_version,
)
from .project_git_validation import ProjectGitValidation
from .protocol_values import (
    DIRECT_ENROLLMENT_CAPABILITY, PLUGIN_VERSION,
    _activity_label, _opaque, _positive, _session_coordinate, _validate_envelope,
)
from .wiki_contract import (
    WIKI_OPERATIONS, available_wiki_operations,
    bounded_result as bound_wiki_result, validate_payload as validate_wiki_payload,
)
from .workspace_operations import GROUP_HANDLERS, WORKSPACE_HANDLERS

MAX_AVATAR_WORKSPACE_PLAINTEXT_BYTES = 2_800_000


AVAILABLE_WIKI_OPERATIONS = available_wiki_operations()
GROUPS_OPERATIONS = frozenset(GROUP_HANDLERS)
# Live controls are adapter-owned, not generic backend handlers. Keep the
# controller invariant scoped to its actual handlers. Both sets share the same
# authenticated workspace envelope and reliable result serializer.
LIVE_VOICE_OPERATIONS = frozenset({
    "voice.live.status", "voice.live.offer", "voice.live.close",
    "voice.live.jobs", "voice.live.control",
})

WORKSPACE_OPERATIONS = frozenset(WORKSPACE_HANDLERS) | AVAILABLE_WIKI_OPERATIONS


@dataclass(frozen=True)
class WorkspaceRequest:
    request_id: str
    operation: str
    payload: dict[str, Any]
    sent_at: int
    groups_result_version: int | None = None

    def wire_value(self) -> dict[str, Any]:
        return {
            "version": 1,
            "type": "workspace.request",
            "requestId": self.request_id,
            "operation": self.operation,
            "payload": dict(self.payload),
            "sentAt": self.sent_at,
            **({"groupsResultVersion": self.groups_result_version}
               if self.groups_result_version is not None else {}),
        }


def parse_workspace_request(value: dict[str, Any]) -> WorkspaceRequest:
    expected = {"version", "type", "requestId", "operation", "payload", "sentAt"}
    _validate_envelope(
        value, expected, "workspace.request", "Loopdy Link workspace request is invalid",
        strict_version=False, optional={"groupsResultVersion"},
    )
    operation = value.get("operation")
    if not isinstance(operation, str) or operation not in WORKSPACE_OPERATIONS | LIVE_VOICE_OPERATIONS:
        raise ValueError("Loopdy Link workspace operation is invalid")
    groups_result_version = (
        validate_result_version(value["groupsResultVersion"], operation)
        if "groupsResultVersion" in value else None
    )
    if operation in AVAILABLE_WIKI_OPERATIONS:
        if type(value.get("version")) is not int:
            raise ValueError("Wiki request is invalid")
        payload = validate_wiki_payload(operation, value.get("payload"))
    elif operation.startswith("projects.git."):
        payload = _project_git_workspace_payload(operation, value.get("payload"))
    elif operation in {"agents.create", "agents.update", "agents.avatar.set"}:
        payload = _workspace_json_allowing_avatar_blobs(value.get("payload"))
    elif operation == "skills_tools.import":
        payload = _workspace_json_allowing_skill_archive(value.get("payload"))
    else:
        payload = _workspace_json(value.get("payload"), depth=0)
    if not isinstance(payload, dict):
        raise ValueError("Loopdy Link workspace payload is invalid")
    return WorkspaceRequest(
        request_id=_opaque(value.get("requestId"), "requestId", 16, 128),
        operation=operation,
        payload=payload,
        sent_at=_positive(value.get("sentAt"), "sentAt"),
        groups_result_version=groups_result_version,
    )


def workspace_capabilities(*, live_voice: bool = True, direct_enrollment: bool = False) -> dict[str, Any]:
    wiki_operations = available_wiki_operations()
    features = [
        "workspace-rejected-v1", "backpressure-v1", "plugin-update-v1",
        "host-runtime-diagnostics-v1", "voice-settings-v1", "session-state-v1", GROUPS_RESULTS_CAPABILITY,
        "direct-configuration-v1",
    ]
    if live_voice:
        features.append("live-voice-v1")
    if direct_enrollment:
        features.append(DIRECT_ENROLLMENT_CAPABILITY)
    if wiki_operations:
        features.append("wiki.v1")
    return {
        "protocolVersion": 1,
        "pluginVersion": PLUGIN_VERSION,
        "features": features,
        "operations": sorted(WORKSPACE_OPERATIONS - WIKI_OPERATIONS | wiki_operations
                             | (LIVE_VOICE_OPERATIONS if live_voice else frozenset())),
    }


def workspace_rejection(value: Any, *, sent_at: int) -> dict[str, Any] | None:
    """Correlate a rejected request without constructing a supported request.

    Called only after authenticated decryption and failed request validation.
    Never echo operation names, invalid payloads, or exception details.
    """
    if not isinstance(value, dict) or value.get("type") != "workspace.request":
        return None
    try:
        request_id = _opaque(value.get("requestId"), "requestId", 16, 128)
    except ValueError:
        return None
    operation = value.get("operation")
    unsupported = (
        type(value.get("version")) is int and value.get("version") == 1
        and isinstance(operation, str)
        and re.fullmatch(r"[A-Za-z0-9_.-]{1,96}", operation) is not None
        and operation not in WORKSPACE_OPERATIONS | LIVE_VOICE_OPERATIONS
    )
    return {
        "version": 1,
        "type": "workspace.rejected",
        "requestId": request_id,
        "code": "unsupported_operation" if unsupported else "invalid_request",
        "message": (
            "This host does not support that operation."
            if unsupported else "This workspace request is invalid."
        ),
        "sentAt": _positive(sent_at, "sentAt"),
    }


def workspace_result(
    *,
    request: WorkspaceRequest,
    status: str,
    payload: dict[str, Any],
    sent_at: int,
    code: str | None = None,
    message: str | None = None,
) -> dict[str, Any]:
    if status not in {"completed", "failed", "conflict"}:
        raise ValueError("Loopdy Link workspace result status is invalid")
    if request.groups_result_version is not None:
        validate_result_version(request.groups_result_version, request.operation)
    if request.operation in AVAILABLE_WIKI_OPERATIONS:
        payload = bound_wiki_result(payload)
    if request.operation == "groups.log" and status == "completed":
        validate_log_page(payload, request.payload)
    projected = (
        _workspace_json_allowing_dashboard_cards(payload)
        if request.operation == "dashboard.load" and status == "completed"
        else _workspace_json_allowing_avatar_blobs(payload)
        if request.operation in {
            "agents.create",
            "agents.update",
            "agents.avatar.get",
        }
        else _workspace_json(
            payload,
            depth=0,
            allowed_sensitive_keys=(
                frozenset({"statusToken", "confirmationToken"})
                if request.operation.startswith("projects.git.")
                else frozenset()
            ),
            allowed_gateway_paths=(
                frozenset({("authority", "gateway_id")})
                if request.operation == "groups.log" and status == "completed"
                else frozenset()
            ),
            maximum_bytes=GROUPS_RESULT_PAYLOAD_BYTES if request.groups_result_version == 1 else 196_608,
        )
    )
    if not isinstance(projected, dict):
        raise ValueError("Loopdy Link workspace result payload is invalid")
    result: dict[str, Any] = {
        "version": 1,
        "type": "workspace.result",
        "requestId": request.request_id,
        "operation": request.operation,
        "status": status,
        "payload": projected,
        "sentAt": _positive(sent_at, "sentAt"),
    }
    if request.groups_result_version == 1:
        result["groupsResultVersion"] = 1
    if (code is None) != (message is None):
        raise ValueError("Loopdy Link workspace error fields are invalid")
    if code is not None and message is not None:
        if not re.fullmatch(r"[A-Za-z0-9_]{1,80}", code):
            raise ValueError("Loopdy Link workspace error code is invalid")
        result["code"] = code
        result["message"] = _activity_label(message, "message", 2_000)
    if request.groups_result_version == 1 and len(
        json.dumps(result, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    ) > GROUPS_RESULT_ENVELOPE_BYTES:
        raise ValueError("Loopdy Link workspace result envelope is too large")
    return result


def _project_git_workspace_payload(operation: str, value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError("Loopdy Link Project Git payload is invalid")
    base_keys = {"agentId", "sessionId", "workspaceId"}
    suffix = operation.removeprefix("projects.git.")
    expected = {
        "capabilities": base_keys,
        "status": base_keys,
        "diff": base_keys | {"path", "side", "statusToken", "offset", "limit"},
        "prepare": base_keys | {"operation", "statusToken", "input"},
        "execute": base_keys
        | {
            "operation",
            "statusToken",
            "input",
            "confirmationToken",
            "idempotencyKey",
        },
    }.get(suffix)
    if expected is None or set(value) != expected:
        raise ValueError("Loopdy Link Project Git payload is invalid")
    projected: dict[str, Any] = {
        "agentId": _opaque(value.get("agentId"), "agentId", 1, 64),
        "sessionId": _session_coordinate(value.get("sessionId")),
        "workspaceId": _opaque(value.get("workspaceId"), "workspaceId", 1, 160),
    }
    if suffix == "diff":
        projected.update(
            {
                "path": _project_git_path(value.get("path")),
                "side": _project_git_choice(value.get("side"), {"staged", "worktree"}),
                "statusToken": _project_git_status_token(value.get("statusToken")),
                "offset": _bounded_integer(value.get("offset"), 0, 100_000),
                "limit": _bounded_integer(value.get("limit"), 1, 500),
            }
        )
    elif suffix in {"prepare", "execute"}:
        git_operation = _project_git_choice(
            value.get("operation"), {"stage", "commit", "fetch", "pull", "push"}
        )
        projected.update(
            {
                "operation": git_operation,
                "statusToken": _project_git_status_token(value.get("statusToken")),
                "input": _project_git_input(git_operation, value.get("input")),
            }
        )
        if suffix == "execute":
            projected["confirmationToken"] = _opaque(
                value.get("confirmationToken"), "confirmationToken", 16, 200
            )
            key = value.get("idempotencyKey")
            if not isinstance(key, str) or not re.fullmatch(
                r"[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}",
                key,
            ):
                raise ValueError("Loopdy Link Project Git idempotency key is invalid")
            projected["idempotencyKey"] = key
    return projected


_git_values = ProjectGitValidation(ValueError, 'Loopdy Link Project Git', choice_label='choice')
_project_git_input = _git_values.operation_input
_project_git_path = _git_values.relative_path
_project_git_ref_name = _git_values.ref
_project_git_choice = _git_values.choice
_project_git_status_token = _git_values.status_token


def _bounded_integer(value: Any, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        raise ValueError("Loopdy Link Project Git page is invalid")
    return value


def _workspace_json(
    value: Any,
    *,
    depth: int,
    allowed_sensitive_keys: frozenset[str] = frozenset(),
    allowed_gateway_paths: frozenset[tuple[str, ...]] = frozenset(),
    path: tuple[str, ...] = (),
    maximum_bytes: int = 196_608,
) -> Any:
    if depth > 8:
        raise ValueError("Loopdy Link workspace payload is invalid")
    if value is None or isinstance(value, bool):
        return value
    if isinstance(value, int) and not isinstance(value, bool):
        return value
    if isinstance(value, float):
        if not math.isfinite(value):
            raise ValueError("Loopdy Link workspace payload is invalid")
        return value
    if isinstance(value, str):
        if len(value.encode("utf-8")) > 256_000 or any(
            ord(character) < 32 and character not in "\n\r\t"
            for character in value
        ):
            raise ValueError("Loopdy Link workspace payload is invalid")
        return value
    if isinstance(value, list):
        if len(value) > 500:
            raise ValueError("Loopdy Link workspace payload is invalid")
        projected = [
            _workspace_json(
                item,
                depth=depth + 1,
                allowed_sensitive_keys=allowed_sensitive_keys,
                allowed_gateway_paths=allowed_gateway_paths,
                path=(*path, str(index)),
            )
            for index, item in enumerate(value)
        ]
    elif isinstance(value, dict):
        if len(value) > 200:
            raise ValueError("Loopdy Link workspace payload is invalid")
        projected = {}
        for key, item in value.items():
            if (
                not isinstance(key, str)
                or not re.fullmatch(r"[A-Za-z0-9_.-]{1,64}", key)
            ):
                raise ValueError("Loopdy Link workspace payload key is invalid")
            canonical = "".join(character for character in key.lower() if character.isalnum())
            if (
                (canonical.startswith("gateway") and (*path, key) not in allowed_gateway_paths)
                or (canonical.endswith("token") and key not in allowed_sensitive_keys)
                or any(
                    forbidden in canonical
                    for forbidden in (
                        "authorization",
                        "cookie",
                        "credential",
                        "password",
                        "secret",
                    )
                )
            ):
                raise ValueError("Loopdy Link workspace payload key is invalid")
            projected[key] = _workspace_json(
                item,
                depth=depth + 1,
                allowed_sensitive_keys=allowed_sensitive_keys,
                allowed_gateway_paths=allowed_gateway_paths,
                path=(*path, key),
            )
    else:
        raise ValueError("Loopdy Link workspace payload is invalid")
    if depth == 0 and len(
        json.dumps(
            projected,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
    ) > maximum_bytes:
        raise ValueError("Loopdy Link workspace payload is invalid")
    return projected


def _workspace_json_allowing_dashboard_cards(value: Any) -> Any:
    """Validate optional card documents separately from their Inbox wrappers.

    Only this response-owned path gets a separate bounded depth budget. All
    card keys still pass secret screening, and the aggregate byte cap remains
    unchanged. A bad optional card cannot make ordinary events unavailable.
    """
    if not isinstance(value, dict) or not isinstance(value.get("events"), list):
        return _workspace_json(value, depth=0)
    events = value["events"]
    if len(events) > 500:
        raise ValueError("Loopdy Link workspace payload is invalid")
    stripped_events = []
    cards = []
    for index, event in enumerate(events):
        if not isinstance(event, dict) or not isinstance(event.get("detail"), dict):
            stripped_events.append(event)
            continue
        detail = dict(event["detail"])
        card = detail.pop("generative_ui", None)
        stripped_events.append({**event, "detail": detail})
        if card is not None:
            try:
                screened = _workspace_json(card, depth=0)
                cards.append((index, validate_rendered_envelope(screened)))
            except (TypeError, ValueError):
                continue
    projected = _workspace_json({**value, "events": stripped_events}, depth=0)
    for index, card in cards:
        detail = projected["events"][index]["detail"]
        detail["generative_ui"] = card
        if len(json.dumps(projected, ensure_ascii=False, separators=(",", ":"),
                          sort_keys=True).encode("utf-8")) > 196_608:
            del detail["generative_ui"]
    return projected


def _workspace_json_allowing_skill_archive(value: Any) -> Any:
    if not isinstance(value, dict):
        raise ValueError("Loopdy Link workspace payload is invalid")
    encoded = value.get("dataBase64")
    if not isinstance(encoded, str) or not 1 <= len(encoded) <= 2_100_000:
        raise ValueError("Loopdy Link skill archive is invalid")
    try:
        base64.b64decode(encoded, validate=True)
    except (ValueError, TypeError) as exc:
        raise ValueError("Loopdy Link skill archive is invalid") from exc
    placeholder = dict(value)
    placeholder["dataBase64"] = "AA=="
    _workspace_json(placeholder, depth=0)
    return value


def _workspace_json_allowing_avatar_blobs(value: Any) -> Any:
    projected = _workspace_json(_workspace_avatar_placeholder_value(value), depth=0)
    _validate_workspace_avatar_blobs(value)
    return value if projected != value else projected


def _workspace_avatar_placeholder_value(value: Any) -> Any:
    if isinstance(value, dict):
        projected = {}
        for key, item in value.items():
            if key == "avatar" and item is not None:
                _avatar_payload(item)
                projected[key] = {
                    "mimeType": "image/png",
                    "byteCount": 1,
                    "sha256": "validated-avatar-sha256",
                    "data": "data:image/png;base64,AA==",
                }
            else:
                projected[key] = _workspace_avatar_placeholder_value(item)
        return projected
    if isinstance(value, list):
        return [_workspace_avatar_placeholder_value(item) for item in value]
    return value


def _validate_workspace_avatar_blobs(value: Any) -> None:
    if isinstance(value, dict):
        for key, item in value.items():
            if key == "avatar" and item is not None:
                _avatar_payload(item)
            else:
                _validate_workspace_avatar_blobs(item)
    elif isinstance(value, list):
        for item in value:
            _validate_workspace_avatar_blobs(item)


def _avatar_payload(value: Any) -> dict[str, Any]:
    avatar = value
    if not isinstance(avatar, dict) or set(avatar) != {"mimeType", "byteCount", "sha256", "data"}:
        raise ValueError("Loopdy Link workspace payload is invalid")
    if avatar.get("mimeType") not in {"image/png", "image/jpeg", "image/webp"}:
        raise ValueError("Loopdy Link workspace payload is invalid")
    byte_count = avatar.get("byteCount")
    if not isinstance(byte_count, int) or isinstance(byte_count, bool) or byte_count <= 0:
        raise ValueError("Loopdy Link workspace payload is invalid")
    sha256 = avatar.get("sha256")
    if not isinstance(sha256, str) or not 16 <= len(sha256) <= 128:
        raise ValueError("Loopdy Link workspace payload is invalid")
    data = avatar.get("data")
    if not isinstance(data, str) or len(data) > MAX_AVATAR_WORKSPACE_PLAINTEXT_BYTES:
        raise ValueError("Loopdy Link workspace payload is invalid")
    prefix = f"data:{avatar['mimeType']};base64,"
    if not data.startswith(prefix):
        raise ValueError("Loopdy Link workspace payload is invalid")
    try:
        blob = base64.b64decode(data.removeprefix(prefix), validate=True)
    except ValueError as exc:
        raise ValueError("Loopdy Link workspace payload is invalid") from exc
    if len(blob) != byte_count:
        raise ValueError("Loopdy Link workspace payload is invalid")
    return avatar
