"""Store value validation and row projections; no connection or delivery ownership."""

from __future__ import annotations

import errno
import hashlib
import hmac
import json
import os
import re
import sqlite3
import time
import uuid
from datetime import datetime, timezone
from typing import Any, Mapping
from .loopdy_cards import canonical_json as canonical_card_json
from .loopdy_cards import validate_card_input


_PROTOCOL_IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,179}$")

_MAX_SAFE_REVISION = 9_007_199_254_740_991

_MAX_TIMESTAMP = 9_999_999_999

_UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")

_MAX_RELAY_AUTOMATIC_ATTEMPTS = 5

_CLAIM_LEASE_SECONDS = 30

_LEGACY_RELAY_PROVIDER_CONFLICT = "Device is already registered with another provider"

_GATEWAY_LIFECYCLE_PREFIXES = (
    "♻️ Gateway online",
    "♻ Gateway online",
    "♻️ Gateway restarted",
    "♻ Gateway restarted",
    "⚠️ Gateway restarting",
    "⚠ Gateway restarting",
    "⚠️ Gateway shutting down",
    "⚠ Gateway shutting down",
)


class CardTemplateConflict(ValueError):
    """A template changed under the caller's expected version/content."""


class CardTemplateLimit(ValueError):
    """A bounded template catalog cannot represent all stored rows."""


def _lock_file_descriptor(descriptor: int) -> None:
    if os.name == "nt":
        import msvcrt

        if os.fstat(descriptor).st_size == 0:
            os.write(descriptor, b"\0")
        os.lseek(descriptor, 0, os.SEEK_SET)
        while True:
            try:
                msvcrt.locking(descriptor, msvcrt.LK_NBLCK, 1)
                return
            except OSError as error:
                if error.errno not in {errno.EACCES, errno.EAGAIN, errno.EDEADLK}:
                    raise
                time.sleep(0.05)

    import fcntl

    fcntl.flock(descriptor, fcntl.LOCK_EX)


def _unlock_file_descriptor(descriptor: int) -> None:
    if os.name == "nt":
        import msvcrt

        os.lseek(descriptor, 0, os.SEEK_SET)
        msvcrt.locking(descriptor, msvcrt.LK_UNLCK, 1)
        return

    import fcntl

    fcntl.flock(descriptor, fcntl.LOCK_UN)


def _event_row(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "event_id": row["event_id"],
        "type": row["type"],
        "status": row["status"],
        "target": row["target"],
        "profile": row["profile"],
        "session_id": row["session_id"] or None,
        "job_id": row["job_id"] or None,
        "task_id": row["task_id"] or None,
        "approval_id": row["approval_id"] or None,
        "delegation_id": row["delegation_id"] or None,
        "detail": _load_json(row["detail_json"], {}),
        "push": _load_json(row["push_json"], {}),
        "created_at": row["created_at"],
        "delivered_at": row["delivered_at"],
        "delivery_id": row["delivery_id"] or None,
        "failure": row["failure"],
        "dismissed_at": row["dismissed_at"],
        "is_read": row["read_at"] is not None,
        "is_pinned": row["pinned_at"] is not None,
    }


def _device_row(row: sqlite3.Row) -> dict[str, Any]:
    result = {
        "device_id": row["device_id"],
        "endpoint_id": row["endpoint_id"],
        "provider": row["provider"],
        "token_environment": row["token_environment"],
        "label": row["label"],
        "groups": _load_json(row["groups_json"], []),
        "preferences": _load_json(row["preferences_json"], {}),
        "revoked": row["revoked_at"] is not None,
    }
    if row["provider"] == "relay":
        result.update(
            {
                "recipient_public_key": row["recipient_public_key"],
                "recipient_key_id": row["recipient_key_id"],
                "revision": row["revision"],
                "lease_expires": row["lease_expires"],
                "sender_key_revision": row["sender_key_revision"],
                "relay_generation": row["relay_generation"],
                "acknowledged_sender_key_ids": _load_json(
                    row["acknowledged_sender_key_ids_json"], []
                ),
            }
        )
    return result


def _form_row(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "request_id": row["request_id"],
        "profile": row["profile"],
        "session_id": row["session_id"],
        "form_schema": _load_json(row["form_schema_json"], {}),
        "content_hash": row["content_hash"],
        "state": row["state"],
        "idempotency_key": row["idempotency_key"],
        "request_digest": row["request_digest"],
        "values": _load_json(row["values_json"], None),
        "created_at": row["created_at"],
        "expires_at": row["expires_at"],
        "submitted_at": row["submitted_at"],
        "consumed_at": row["consumed_at"],
    }


def _same_owner(row: sqlite3.Row, profile: str, session_id: str) -> bool:
    return hmac.compare_digest(str(row["profile"]), str(profile)) and hmac.compare_digest(
        str(row["session_id"]), str(session_id)
    )


def _form_request_id(value: Any) -> str:
    normalized = str(value or "").strip()
    if len(normalized) != 32 or any(character not in "0123456789abcdef" for character in normalized):
        raise ValueError("request_id must be 32 lowercase hexadecimal characters")
    return normalized


def _content_hash(value: Any) -> str:
    normalized = str(value or "").strip()
    if len(normalized) != 64 or any(character not in "0123456789abcdef" for character in normalized):
        raise ValueError("content_hash must be 64 lowercase hexadecimal characters")
    return normalized


def _idempotency_key(value: Any) -> str:
    normalized = str(value or "").strip()
    try:
        parsed = uuid.UUID(normalized)
    except (ValueError, AttributeError) as error:
        raise ValueError("idempotency_key must be a lowercase UUID") from error
    if str(parsed) != normalized:
        raise ValueError("idempotency_key must be a lowercase UUID")
    return normalized

_FORM_MESSAGES = {
    "accepted": "Form response accepted.",
    "request_not_found": "Form request was not found.",
    "request_expired": "Form request has expired.",
    "owner_mismatch": "Form request belongs to another session.",
    "invalid_value": "One or more form values are invalid.",
    "already_submitted": "Form response was already submitted.",
    "already_consumed": "Form response was already consumed.",
    "idempotency_conflict": "Idempotency key was reused with different values.",
    "payload_too_large": "Form response exceeds the byte limit.",
    "internal_error": "Form response could not be processed.",
}


def _form_response(request_id: str, idempotency_key: str, state: str, code: str) -> dict[str, Any]:
    return {
        "schema": "loopdy.generative_ui.action_response",
        "version": 2,
        "request_id": request_id,
        "idempotency_key": idempotency_key,
        "state": state,
        "code": code,
        "message": _FORM_MESSAGES[code],
    }


def form_action_response(request_id: str, idempotency_key: str, state: str, code: str) -> dict[str, Any]:
    """Build a fixed public envelope without reflecting malformed identifiers."""
    try:
        safe_request_id = _form_request_id(request_id)
    except ValueError:
        safe_request_id = "0" * 32
    return _form_response(safe_request_id, str(idempotency_key or ""), state, code)


def _card_template(value: Mapping[str, Any]) -> dict[str, Any]:
    if not isinstance(value, Mapping):
        raise ValueError("Card template must be an object")
    expected = {
        "id",
        "version",
        "name",
        "summary",
        "author",
        "license",
        "minimum_card_version",
        "parameters_schema",
        "document",
        "sha256",
    }
    if set(value) != expected:
        raise ValueError("Card template schema is invalid")
    normalized = json.loads(canonical_card_json(dict(value)))
    normalized["id"] = _card_template_id(normalized["id"])
    normalized["version"] = _positive_revision(normalized["version"])
    normalized["name"] = _required_text(normalized["name"], "name", 120)
    normalized["summary"] = _required_text(normalized["summary"], "summary", 1_000)
    normalized["author"] = _required_text(normalized["author"], "author", 120)
    normalized["license"] = _required_text(normalized["license"], "license", 120)
    if normalized["minimum_card_version"] != 1:
        raise ValueError("Card template minimum card version is unsupported")
    _card_template_parameters_schema(normalized["parameters_schema"])
    validate_card_input(normalized["document"], now=datetime.now(timezone.utc))
    supplied_hash = _card_template_hash(normalized["sha256"])
    expected_hash = hashlib.sha256(
        canonical_card_json(normalized["document"]).encode("utf-8")
    ).hexdigest()
    if not hmac.compare_digest(supplied_hash, expected_hash):
        raise ValueError("Card template hash does not match its bundle")
    normalized["sha256"] = expected_hash
    return normalized


def _card_template_id(value: Any) -> str:
    if type(value) is not str or re.fullmatch(r"[a-z0-9][a-z0-9._-]{0,127}", value) is None:
        raise ValueError("Card template id is invalid")
    return value


def _card_template_hash(value: Any) -> str:
    if type(value) is not str or re.fullmatch(r"[0-9a-f]{64}", value) is None:
        raise ValueError("Card template hash is invalid")
    return value


def _card_template_parameters_schema(value: Any) -> None:
    if not isinstance(value, dict) or set(value) != {
        "type", "properties", "required", "additionalProperties"
    }:
        raise ValueError("Card template parameters schema is invalid")
    if value["type"] != "object" or value["additionalProperties"] is not False:
        raise ValueError("Card template parameters schema must be a strict object")
    properties = value["properties"]
    required = value["required"]
    if not isinstance(properties, dict):
        raise ValueError("Card template parameter properties are invalid")
    if (
        not isinstance(required, list)
        or len(required) != len(set(required))
        or any(type(item) is not str or item not in properties for item in required)
    ):
        raise ValueError("Card template required parameters are invalid")
    for name, schema in properties.items():
        if re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{0,63}", name) is None:
            raise ValueError("Card template parameter name is invalid")
        if (
            not isinstance(schema, dict)
            or set(schema) - {"type", "title", "description", "default", "enum"}
            or schema.get("type") not in {"string", "integer", "number", "boolean"}
        ):
            raise ValueError("Card template parameter schema is invalid")
        if "title" in schema:
            _required_text(schema["title"], "parameter title", 120)
        if "description" in schema:
            _required_text(schema["description"], "parameter description", 500)
        if "enum" in schema:
            enum = schema["enum"]
            if not isinstance(enum, list) or not enum:
                raise ValueError("Card template parameter enum is invalid")
            if len({canonical_card_json(item) for item in enum}) != len(enum):
                raise ValueError("Card template parameter enum is invalid")
            for item in enum:
                _card_template_parameter_value(item, schema["type"])
        if "default" in schema:
            _card_template_parameter_value(schema["default"], schema["type"])
            if "enum" in schema and schema["default"] not in schema["enum"]:
                raise ValueError("Card template parameter default is invalid")


def _card_template_parameter_value(value: Any, kind: str) -> None:
    valid = (
        (kind == "string" and isinstance(value, str))
        or (kind == "integer" and type(value) is int)
        or (kind == "number" and type(value) in {int, float})
        or (kind == "boolean" and type(value) is bool)
    )
    if not valid:
        raise ValueError("Card template parameter value is invalid")


def _identifier(value: str, name: str) -> str:
    return _required_text(value, name, 180)


def _required_text(value: str, name: str, maximum: int) -> str:
    normalized = str(value or "").strip()
    if not normalized or len(normalized) > maximum:
        raise ValueError(f"{name} must be between 1 and {maximum} characters")
    return normalized


def _provider_mode(value: Any) -> str:
    normalized = str(value or "").strip().lower()
    if normalized == "relay":
        return "managed"
    if normalized not in {"managed", "direct"}:
        raise ValueError("Loopdy provider mode must be managed or direct")
    return normalized


def _device_provider(value: Any) -> str:
    normalized = str(value or "").strip().lower()
    if normalized not in {"managed", "direct", "relay", "legacy_relay"}:
        raise ValueError("Loopdy device provider must be managed, direct, or relay")
    return normalized


def _delivery_status(value: Any) -> str:
    normalized = str(value or "").strip().lower()
    if normalized not in {"queued", "sent", "failed", "suppressed"}:
        raise ValueError("Invalid device delivery status")
    return normalized


def _text(value: Any, maximum: int) -> str:
    return " ".join(str(value or "").split())[:maximum]


def _json(value: Any) -> str:
    try:
        return json.dumps(
            value,
            separators=(",", ":"),
            sort_keys=True,
            ensure_ascii=False,
            allow_nan=False,
        )
    except (TypeError, ValueError) as error:
        raise ValueError("Value is not canonical JSON") from error


def _relay_operation_name(value: Any) -> str:
    normalized = _required_text(value, "operation", 80)
    return "revoke_device" if normalized == "device_revoke" else normalized


def _normalized_body_digest(value: Mapping[str, Any]) -> str:
    try:
        encoded = json.dumps(
            dict(value),
            separators=(",", ":"),
            sort_keys=True,
            ensure_ascii=False,
            allow_nan=False,
        ).encode("utf-8")
    except (TypeError, ValueError) as error:
        raise ValueError("Relay body is not canonical JSON") from error
    return hashlib.sha256(encoded).hexdigest()


def _positive_revision(value: Any) -> int:
    if (
        type(value) is not int
        or value <= 0
        or value > _MAX_SAFE_REVISION
    ):
        raise ValueError("Relay revision must be a positive integer")
    return value


def _positive_integer(value: Any, name: str) -> int:
    if type(value) is not int or value <= 0 or value > _MAX_TIMESTAMP:
        raise ValueError(f"{name} must be a positive integer")
    return value


def _protocol_identifier(value: Any, name: str) -> str:
    if type(value) is not str or _PROTOCOL_IDENTIFIER.fullmatch(value) is None:
        raise ValueError(f"{name} must be a printable ASCII protocol identifier")
    return value


def _load_json(value: str, default: Any) -> Any:
    try:
        return json.loads(value)
    except (TypeError, json.JSONDecodeError):
        return default
