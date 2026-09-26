"""Phone-tool envelopes and argument policy shared by native and paired clients."""
from __future__ import annotations

import json
import math
import re
from datetime import datetime
from typing import Any

from .protocol_values import _opaque, _positive, _session_coordinate, _validate_envelope

# Native DeviceToolCoordinator bounds the complete envelope at 20 KiB and the
# arguments portion at 16 KiB. Keep the host-side parser at the same limits so
# a payload accepted here cannot be rejected after it reaches the phone.
MAX_DEVICE_TOOL_PAYLOAD_BYTES = 20 * 1024
MAX_DEVICE_TOOL_ARGUMENT_BYTES = 16 * 1024
MAX_DEVICE_TOOL_DATE_RANGE_SECONDS = 31 * 24 * 60 * 60
MAX_DEVICE_TOOL_LIST_LIMIT = 200
MAX_DEVICE_TOOL_ID_COUNT = 50
DEVICE_TOOL_CAPABILITY = "device-tools-v1"


DEVICE_TOOL_OPERATIONS = frozenset(
    {
        "health.read",
        "calendar.list", "calendar.create", "calendar.update", "calendar.delete",
        "reminders.list", "reminders.create", "reminders.update", "reminders.delete",
    }
)
HEALTH_TYPES = (
    "step_count",
    "distance_walking_running",
    "active_energy_burned",
    "basal_energy_burned",
    "flights_climbed",
    "apple_exercise_time",
    "apple_stand_time",
    "sleep_analysis",
    "heart_rate",
    "resting_heart_rate",
    "walking_heart_rate_average",
    "heart_rate_variability_sdnn",
    "oxygen_saturation",
    "respiratory_rate",
    "blood_pressure_systolic",
    "blood_pressure_diastolic",
    "height",
    "body_mass",
    "body_mass_index",
    "lean_body_mass",
    "body_fat_percentage",
    "workout",
)


def device_tool_request(
    *,
    request_id: str,
    device_id: str,
    host_id: str,
    authorization_epoch: int,
    session_id: str,
    agent_id: str,
    turn_id: str,
    operation: str,
    arguments: dict[str, Any],
    sent_at: int,
    expires_at: int,
) -> dict[str, Any]:
    """Build one bounded host-to-phone device-tool request."""
    value = {
        "version": 1,
        "type": "device.tool.request",
        "requestId": request_id,
        "deviceId": device_id,
        "hostId": host_id,
        "authorizationEpoch": authorization_epoch,
        "sessionId": session_id,
        "agentId": agent_id,
        "turnId": turn_id,
        "operation": operation,
        "arguments": arguments,
        "sentAt": sent_at,
        "expiresAt": expires_at,
    }
    return parse_device_tool_request(value)


def parse_device_tool_request(value: Any) -> dict[str, Any]:
    expected = {
        "version", "type", "requestId", "deviceId", "hostId", "authorizationEpoch",
        "sessionId", "agentId", "turnId", "operation", "arguments", "sentAt", "expiresAt",
    }
    _validate_envelope(
        value, expected, "device.tool.request", "Loopdy Link device tool request is invalid",
        strict_version=True,
    )
    request_id = _opaque(value.get("requestId"), "requestId", 16, 128)
    device_id = _opaque(value.get("deviceId"), "deviceId", 1, 96)
    host_id = _opaque(value.get("hostId"), "hostId", 1, 96)
    epoch = _positive(value.get("authorizationEpoch"), "authorizationEpoch")
    session_id = _session_coordinate(value.get("sessionId"))
    agent_id = _opaque(value.get("agentId"), "agentId", 1, 96)
    turn_id = _device_tool_turn_id(value.get("turnId"))
    operation = _device_tool_operation(value.get("operation"))
    arguments = _device_tool_arguments(operation, value.get("arguments"))
    if _json_size(arguments) > MAX_DEVICE_TOOL_ARGUMENT_BYTES:
        raise ValueError("Loopdy Link device tool arguments are too large")
    sent_at = _positive(value.get("sentAt"), "sentAt")
    expires_at = _positive(value.get("expiresAt"), "expiresAt")
    if not 20 <= expires_at - sent_at <= 60:
        raise ValueError("Loopdy Link device tool expiry is invalid")
    result = dict(value)
    result.update(
        requestId=request_id,
        deviceId=device_id,
        hostId=host_id,
        authorizationEpoch=epoch,
        sessionId=session_id,
        agentId=agent_id,
        turnId=turn_id,
        operation=operation,
        arguments=arguments,
        sentAt=sent_at,
        expiresAt=expires_at,
    )
    if _json_size(result) > MAX_DEVICE_TOOL_PAYLOAD_BYTES:
        raise ValueError("Loopdy Link device tool request is too large")
    return result


def device_tool_result(
    *, request: dict[str, Any], status: str, payload: dict[str, Any], sent_at: int,
    code: str | None = None,
) -> dict[str, Any]:
    request = parse_device_tool_request(request)
    result_sent_at = _positive(sent_at, "sentAt")
    if result_sent_at < request["sentAt"]:
        raise ValueError("Loopdy Link device tool result timestamp is invalid")
    result = {
        "version": 1,
        "type": "device.tool.result",
        "requestId": request["requestId"],
        "deviceId": request["deviceId"],
        "hostId": request["hostId"],
        "authorizationEpoch": request["authorizationEpoch"],
        "sessionId": request["sessionId"],
        "agentId": request["agentId"],
        "turnId": request["turnId"],
        "operation": request["operation"],
        "status": status,
        "payload": payload,
        "sentAt": result_sent_at,
    }
    if code is not None:
        result["code"] = code
    return parse_device_tool_result(result, sender_device_id=request["deviceId"])


def parse_device_tool_result(
    value: Any,
    *,
    sender_device_id: str | None = None,
    sender_epoch: int | None = None,
) -> dict[str, Any]:
    required = {
        "version", "type", "requestId", "deviceId", "hostId", "authorizationEpoch",
        "sessionId", "agentId", "turnId", "operation", "status", "payload", "sentAt",
    }
    _validate_envelope(
        value, required, "device.tool.result", "Loopdy Link device tool result is invalid",
        strict_version=True, optional={"code"},
    )
    device_id = _opaque(value.get("deviceId"), "deviceId", 1, 96)
    if sender_device_id is not None and device_id != sender_device_id:
        raise ValueError("Loopdy Link device tool result sender is invalid")
    if sender_epoch is not None and value.get("authorizationEpoch") != sender_epoch:
        raise ValueError("Loopdy Link device tool result epoch is invalid")
    if value.get("status") not in {"completed", "failed"}:
        raise ValueError("Loopdy Link device tool result status is invalid")
    if not isinstance(value.get("payload"), dict):
        raise ValueError("Loopdy Link device tool result payload is invalid")
    payload = _device_tool_json(value["payload"])
    code = value.get("code")
    if code is not None:
        code = _opaque(code, "code", 1, 80)
    result = dict(value)
    result.update(
        requestId=_opaque(value.get("requestId"), "requestId", 16, 128),
        deviceId=device_id,
        hostId=_opaque(value.get("hostId"), "hostId", 1, 96),
        authorizationEpoch=_positive(value.get("authorizationEpoch"), "authorizationEpoch"),
        sessionId=_session_coordinate(value.get("sessionId")),
        agentId=_opaque(value.get("agentId"), "agentId", 1, 96),
        turnId=_device_tool_turn_id(value.get("turnId")),
        operation=_device_tool_operation(value.get("operation")),
        payload=payload,
        sentAt=_positive(value.get("sentAt"), "sentAt"),
    )
    if code is None:
        result.pop("code", None)
    else:
        result["code"] = code
    if _json_size(result) > MAX_DEVICE_TOOL_PAYLOAD_BYTES:
        raise ValueError("Loopdy Link device tool result is too large")
    return result


def device_tool_status(
    *, device_id: str, host_id: str, authorization_epoch: int,
    enabled: list[str], available: bool, sent_at: int,
) -> dict[str, Any]:
    return parse_device_tool_status(
        {
            "version": 1,
            "type": "device.tools.status",
            "deviceId": device_id,
            "hostId": host_id,
            "authorizationEpoch": authorization_epoch,
            "enabled": enabled,
            "available": available,
            "sentAt": sent_at,
        },
        sender_device_id=device_id,
    )


def parse_device_tool_status(
    value: Any,
    *,
    sender_device_id: str | None = None,
    sender_epoch: int | None = None,
) -> dict[str, Any]:
    expected = {"version", "type", "deviceId", "hostId", "authorizationEpoch", "enabled", "available", "sentAt"}
    _validate_envelope(
        value, expected, "device.tools.status", "Loopdy Link device tool status is invalid",
        strict_version=True,
    )
    device_id = _opaque(value.get("deviceId"), "deviceId", 1, 96)
    if sender_device_id is not None and device_id != sender_device_id:
        raise ValueError("Loopdy Link device tool status sender is invalid")
    if sender_epoch is not None and value.get("authorizationEpoch") != sender_epoch:
        raise ValueError("Loopdy Link device tool status epoch is invalid")
    enabled = value.get("enabled")
    if (
        not isinstance(enabled, list) or len(enabled) > 3
        or any(item not in {"health", "calendar", "reminders"} for item in enabled)
        or len(set(enabled)) != len(enabled)
        or not isinstance(value.get("available"), bool)
    ):
        raise ValueError("Loopdy Link device tool status is invalid")
    return {
        **value,
        "deviceId": device_id,
        "hostId": _opaque(value.get("hostId"), "hostId", 1, 96),
        "authorizationEpoch": _positive(value.get("authorizationEpoch"), "authorizationEpoch"),
        "sentAt": _positive(value.get("sentAt"), "sentAt"),
    }


def _device_tool_turn_id(value: Any) -> str:
    # Hermes uses session:task:nonce turn coordinates. Preserve the official
    # identity on both sides of the phone round trip; do not hash or strip it.
    # ASCII keeps the bound equal to iOS DeviceToolCoordinator's 512-byte limit.
    if (
        not isinstance(value, str)
        or re.fullmatch(r"[A-Za-z0-9_:-]{1,512}", value) is None
    ):
        raise ValueError("Loopdy Link device tool turnId is invalid")
    return value


def _device_tool_operation(value: Any) -> str:
    if not isinstance(value, str) or value not in DEVICE_TOOL_OPERATIONS:
        raise ValueError("Loopdy Link device tool operation is invalid")
    return value


def _device_tool_json(value: Any, *, depth: int = 0) -> Any:
    if depth > 4:
        raise ValueError("Loopdy Link device tool JSON is too deep")
    if value is None or isinstance(value, (str, bool, int, float)):
        if isinstance(value, float) and (not math.isfinite(value)):
            raise ValueError("Loopdy Link device tool JSON is invalid")
        if isinstance(value, str) and len(value) > 8_000:
            raise ValueError("Loopdy Link device tool text is too large")
        return value
    if isinstance(value, list):
        if len(value) > 200:
            raise ValueError("Loopdy Link device tool list is too large")
        return [_device_tool_json(item, depth=depth + 1) for item in value]
    if isinstance(value, dict):
        if len(value) > 64:
            raise ValueError("Loopdy Link device tool object is too large")
        return {
            _opaque(key, "device tool key", 1, 96): _device_tool_json(item, depth=depth + 1)
            for key, item in value.items()
        }
    raise ValueError("Loopdy Link device tool JSON is invalid")


def _device_tool_string(value: Any, field: str, *, required: bool = False, maximum: int = 4_000) -> str | None:
    if value is None and not required:
        return None
    if not isinstance(value, str) or not value or len(value) > maximum:
        raise ValueError(f"Loopdy Link device tool {field} is invalid")
    return value


def _device_tool_date(value: Any, field: str, *, required: bool = False) -> str | None:
    raw = _device_tool_string(value, field, required=required, maximum=80)
    if raw is None:
        return None
    try:
        parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
        if parsed.tzinfo is None or parsed.utcoffset() is None:
            raise ValueError
    except (TypeError, ValueError) as exc:
        raise ValueError(f"Loopdy Link device tool {field} is invalid") from exc
    return raw


def _device_tool_range(
    value: dict[str, Any], *, required: bool
) -> None:
    has_start = "start" in value
    has_end = "end" in value
    has_time_zone = "timeZone" in value
    if required or has_start or has_end or has_time_zone:
        start = _device_tool_date(value.get("start"), "start", required=True)
        end = _device_tool_date(value.get("end"), "end", required=True)
        _device_tool_string(value.get("timeZone"), "timeZone", required=True, maximum=128)
        start_date = datetime.fromisoformat(start.replace("Z", "+00:00"))
        end_date = datetime.fromisoformat(end.replace("Z", "+00:00"))
        elapsed = (end_date - start_date).total_seconds()
        if elapsed <= 0 or elapsed > MAX_DEVICE_TOOL_DATE_RANGE_SECONDS:
            raise ValueError("Loopdy Link device tool date range is invalid")


def _device_tool_ordered_dates(
    value: dict[str, Any], start_field: str, end_field: str
) -> None:
    start = _device_tool_date(value.get(start_field), start_field, required=True)
    end = _device_tool_date(value.get(end_field), end_field, required=True)
    start_date = datetime.fromisoformat(start.replace("Z", "+00:00"))
    end_date = datetime.fromisoformat(end.replace("Z", "+00:00"))
    if end_date <= start_date:
        raise ValueError("Loopdy Link device tool date range is invalid")


def _device_tool_limit(value: Any) -> None:
    if value is not None and (
        type(value) is not int or not 1 <= value <= MAX_DEVICE_TOOL_LIST_LIMIT
    ):
        raise ValueError("Loopdy Link device tool limit is invalid")


def _device_tool_id_list(value: dict[str, Any], field: str) -> None:
    if field not in value:
        return
    ids = value[field]
    if (
        not isinstance(ids, list)
        or not 1 <= len(ids) <= MAX_DEVICE_TOOL_ID_COUNT
        or any(not isinstance(item, str) or not item or len(item) > 512 for item in ids)
    ):
        raise ValueError(f"Loopdy Link device tool {field} is invalid")


def _device_tool_arguments(operation: str, value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError("Loopdy Link device tool arguments are invalid")
    common_range = {"start", "end", "timeZone", "limit"}
    allowed: set[str]
    if operation == "health.read":
        allowed = common_range | {"types"}
    elif operation == "calendar.list":
        allowed = common_range | {"calendarIDs"}
    elif operation == "reminders.list":
        allowed = common_range | {"listIDs", "completed", "includeUndated"}
    elif operation == "calendar.create":
        allowed = {"title", "start", "end", "timeZone", "calendarID", "location", "notes", "url", "span"}
    elif operation == "reminders.create":
        allowed = {"title", "listID", "dueDate", "startDate", "timeZone", "notes", "priority"}
    elif operation == "calendar.update":
        allowed = {"id", "expectedRevision", "title", "start", "end", "timeZone", "location", "notes", "url", "span", "occurrenceStart"}
    elif operation == "calendar.delete":
        allowed = {"id", "expectedRevision", "span", "occurrenceStart"}
    elif operation == "reminders.update":
        allowed = {"id", "expectedRevision", "title", "dueDate", "startDate", "timeZone", "notes", "priority", "completed"}
    else:
        allowed = {"id", "expectedRevision"}
    if not set(value).issubset(allowed):
        raise ValueError("Loopdy Link device tool arguments contain an unknown key")
    result = dict(value)
    if operation in {"health.read", "calendar.list"}:
        _device_tool_range(result, required=True)
        _device_tool_limit(result.get("limit"))
    if operation == "health.read" and "types" in result:
        types = result["types"]
        if (
            not isinstance(types, list)
            or not 1 <= len(types) <= len(HEALTH_TYPES)
            or any(item not in HEALTH_TYPES for item in types)
        ):
            raise ValueError("Loopdy Link device tool types are invalid")
    if operation == "calendar.list":
        _device_tool_id_list(result, "calendarIDs")
    elif operation == "reminders.list":
        _device_tool_range(result, required=False)
        _device_tool_limit(result.get("limit"))
        _device_tool_id_list(result, "listIDs")
        if "completed" in result and type(result["completed"]) is not bool:
            raise ValueError("Loopdy Link device tool completed is invalid")
        if "includeUndated" in result and type(result["includeUndated"]) is not bool:
            raise ValueError("Loopdy Link device tool includeUndated is invalid")
    if operation in {"calendar.create", "reminders.create"}:
        _device_tool_string(result.get("title"), "title", required=True)
    if operation.startswith("calendar.") and operation != "calendar.list":
        if operation == "calendar.create":
            _device_tool_ordered_dates(result, "start", "end")
            _device_tool_string(result.get("timeZone"), "timeZone", required=True, maximum=128)
        if operation in {"calendar.update", "calendar.delete"}:
            _device_tool_string(result.get("id"), "id", required=True, maximum=512)
            _device_tool_string(result.get("expectedRevision"), "expectedRevision", required=True, maximum=512)
        if "span" in result and result["span"] != "thisEvent":
            raise ValueError("Loopdy Link device tool recurrence is unsupported")
        for field in ("calendarID", "location", "notes", "url", "title"):
            if field in result:
                _device_tool_string(result[field], field)
        for field in ("start", "end"):
            if field in result:
                _device_tool_date(result[field], field, required=True)
        if "occurrenceStart" in result:
            _device_tool_date(result["occurrenceStart"], "occurrenceStart", required=True)
        if ("start" in result or "end" in result) and "timeZone" not in result:
            raise ValueError("Loopdy Link device tool timeZone is required")
        if "timeZone" in result:
            _device_tool_string(result["timeZone"], "timeZone", required=True, maximum=128)
    if operation.startswith("reminders.") and operation != "reminders.list":
        if operation in {"reminders.update", "reminders.delete"}:
            _device_tool_string(result.get("id"), "id", required=True, maximum=512)
            _device_tool_string(result.get("expectedRevision"), "expectedRevision", required=True, maximum=512)
        if operation == "reminders.create" and "listID" in result:
            _device_tool_string(result["listID"], "listID", maximum=512)
        for field in ("title", "notes"):
            if field in result:
                _device_tool_string(result[field], field)
        for field in ("dueDate", "startDate"):
            if field in result:
                _device_tool_date(result[field], field, required=True)
        if ("dueDate" in result or "startDate" in result) and "timeZone" not in result:
            raise ValueError("Loopdy Link device tool timeZone is required")
        if "timeZone" in result:
            _device_tool_string(result["timeZone"], "timeZone", required=True, maximum=128)
        if "priority" in result and (type(result["priority"]) is not int or not 0 <= result["priority"] <= 9):
            raise ValueError("Loopdy Link device tool priority is invalid")
        if "completed" in result and type(result["completed"]) is not bool:
            raise ValueError("Loopdy Link device tool completed is invalid")
    return _device_tool_json(result)


def _json_size(value: Any) -> int:
    return len(json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
