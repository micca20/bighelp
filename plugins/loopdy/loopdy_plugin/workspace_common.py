"""Shared bounded workspace values and public error types, with no runtime ownership."""

from __future__ import annotations

import logging
import re
from typing import Any


logger = logging.getLogger(f"{__package__}.workspace_control")


class WorkspaceControlError(RuntimeError):
    """A bounded, user-safe workspace control failure."""

    def __init__(
        self,
        message: str,
        *,
        code: str = "workspace_unavailable",
        status: str = "failed",
    ) -> None:
        super().__init__(message)
        self.code = code
        self.status = status


class WorkspaceConflictError(ValueError):
    """The requested coordinate or revision is stale."""


class _HermesMethodUnavailable(WorkspaceControlError):
    """The installed Hermes runtime does not expose a requested native RPC."""

_AGENT_ID = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")


def _empty_payload(payload: Any) -> None:
    if not isinstance(payload, dict) or payload:
        raise WorkspaceControlError("Workspace payload must be empty")


def _object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise WorkspaceControlError(f"{label} is invalid")
    return value


def _optional_object(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _text(value: Any, maximum: int, *, allow_empty: bool = False) -> str:
    if value is None and allow_empty:
        return ""
    if not isinstance(value, str):
        raise WorkspaceControlError("Workspace text is invalid")
    normalized = value.strip()
    if (not normalized and not allow_empty) or len(value.encode("utf-8")) > maximum:
        raise WorkspaceControlError("Workspace text is invalid")
    if any(ord(character) < 32 and character not in "\n\t\r" for character in value):
        raise WorkspaceControlError("Workspace text is invalid")
    return value if allow_empty else normalized


def _utf8_prefix(value: str, maximum: int) -> str:
    encoded = value.encode("utf-8")
    if len(encoded) <= maximum:
        return value
    return encoded[:maximum].decode("utf-8", errors="ignore").rstrip()


def _agent_id(value: Any) -> str:
    candidate = _text(value, 64)
    if not _AGENT_ID.fullmatch(candidate):
        raise WorkspaceControlError("Agent identifier is invalid")
    return candidate


def _coordinate(value: Any, maximum: int) -> str:
    candidate = _text(value, maximum)
    if any(character.isspace() for character in candidate):
        raise WorkspaceControlError("Workspace coordinate is invalid")
    return candidate


def _optional_coordinate(value: Any, maximum: int) -> str | None:
    if value is None or value == "":
        return None
    return _coordinate(value, maximum)


def _nonnegative_integer(value: Any, *, maximum: int) -> int:
    if isinstance(value, bool):
        raise WorkspaceControlError("Workspace number is invalid")
    if isinstance(value, str) and value.isdigit():
        value = int(value)
    if not isinstance(value, int) or value < 0 or value > maximum:
        raise WorkspaceControlError("Workspace number is invalid")
    return value


def _timestamp(value: Any) -> int:
    if isinstance(value, bool):
        raise WorkspaceControlError("Workspace timestamp is invalid")
    if isinstance(value, str):
        try:
            value = float(value)
        except ValueError as exc:
            raise WorkspaceControlError("Workspace timestamp is invalid") from exc
    if not isinstance(value, (int, float)) or value < 0 or value > 4_102_444_800:
        raise WorkspaceControlError("Workspace timestamp is invalid")
    return int(value)


def _agent_id_from_name(value: str) -> str:
    folded = value.casefold()
    parts = re.findall(r"[a-z0-9]+", folded)
    candidate = "-".join(parts)[:64] or "agent"
    return _agent_id(candidate)


def _display_name(agent_id: str) -> str:
    return " ".join(part.capitalize() for part in agent_id.split("-") if part)


def _agent_payload_id(payload: dict[str, Any]) -> str:
    values = _object(payload, "workspace payload")
    if set(values) != {"agentId"}:
        raise WorkspaceControlError("Agent payload is invalid")
    return _agent_id(values.get("agentId"))


def _identifier(value: Any, maximum: int) -> str:
    candidate = _text(value, maximum, allow_empty=True).strip()
    if any(character.isspace() for character in candidate):
        raise WorkspaceControlError("Runtime identifier is invalid")
    return candidate


def _optional_time_value(value: Any) -> int | str | None:
    if value is None or value == "":
        return None
    if isinstance(value, bool):
        raise WorkspaceControlError("Workspace timestamp is invalid")
    if isinstance(value, (int, float)):
        return _timestamp(value)
    if isinstance(value, str):
        stripped = value.strip()
        if not stripped or len(stripped.encode("utf-8")) > 64:
            raise WorkspaceControlError("Workspace timestamp is invalid")
        try:
            return _timestamp(stripped)
        except WorkspaceControlError:
            if "T" in stripped and all(ord(character) >= 32 for character in stripped):
                return stripped
    raise WorkspaceControlError("Workspace timestamp is invalid")


def _coordinate_list(value: Any, *, maximum: int, item_maximum: int) -> list[str]:
    if not isinstance(value, list) or not value or len(value) > maximum:
        raise WorkspaceControlError("Workspace coordinate list is invalid")
    projected = [_coordinate(item, item_maximum) for item in value]
    if len(set(projected)) != len(projected):
        raise WorkspaceControlError("Workspace coordinate list is invalid")
    return projected
