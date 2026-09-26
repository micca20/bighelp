"""Shared scalar validation and negotiated wire values, without transport state."""
from __future__ import annotations

import base64
import re
from typing import Any

DIRECT_ENROLLMENT_CAPABILITY = "direct-enrollment-v1"


_OPAQUE = re.compile(r"^[A-Za-z0-9_-]+$")


# Device-to-host uploads retain the established per-file and aggregate limits.
MAX_ATTACHMENT_BYTES = 8 * 1024 * 1024
MAX_MESSAGE_ATTACHMENT_BYTES = 24 * 1024 * 1024
MAX_ATTACHMENT_CHUNK_BYTES = 64 * 1024
MAX_ATTACHMENT_CHUNKS = 128
# Authenticated host-to-device agent artifacts use the host cache's larger,
# separately bounded allowance without widening user-upload parsing.
MAX_AGENT_ATTACHMENT_BYTES = 25 * 1024 * 1024
MAX_AGENT_ATTACHMENT_CHUNKS = (
    MAX_AGENT_ATTACHMENT_BYTES + MAX_ATTACHMENT_CHUNK_BYTES - 1
) // MAX_ATTACHMENT_CHUNK_BYTES


DIRECTED_FRAMES_CAPABILITY = "directed-frames-v1"


PLUGIN_VERSION = "2.14.9"


def _validate_envelope(
    value: Any, required: set[str], kind: str, error: str, *,
    strict_version: bool, optional: frozenset[str] | set[str] = frozenset(),
) -> None:
    """Check only the shallow shape; domain policy and error order stay local.

    Older envelopes intentionally admit versions equal to 1 (including True
    and 1.0). Phone tools and backpressure instead require an exact int.
    Unknown fields are rejected, never discarded or decoded generically.
    """
    if (
        not isinstance(value, dict)
        or not required <= set(value) <= required | optional
        or (strict_version and type(value.get("version")) is not int)
        or value.get("version") != 1
        or value.get("type") != kind
    ):
        raise ValueError(error)


def _opaque(value: Any, field: str, minimum: int, maximum: int) -> str:
    if (
        not isinstance(value, str)
        or len(value) < minimum
        or len(value) > maximum
        or not _OPAQUE.fullmatch(value)
    ):
        raise ValueError(f"Loopdy Link {field} is invalid")
    return value


def _session_coordinate(value: Any, field: str = "sessionId") -> str:
    """Validate the canonical Hermes session coordinate used across Link."""
    return _opaque(value, field, 1, 180)


def _label(value: Any, field: str, maximum: int) -> str:
    if not isinstance(value, str):
        raise ValueError(f"Loopdy Link {field} is invalid")
    normalized = " ".join(value.split())
    allowed_punctuation = set(" .,'’()&+-_")
    if (
        not normalized
        or normalized != value.strip()
        or len(normalized) > maximum
        or any(not (character.isalnum() or character in allowed_punctuation) for character in normalized)
    ):
        raise ValueError(f"Loopdy Link {field} is invalid")
    return normalized


def _activity_label(value: Any, field: str, maximum: int) -> str:
    if not isinstance(value, str):
        raise ValueError(f"Loopdy Link {field} is invalid")
    normalized = " ".join(value.split())
    if (
        not normalized
        or normalized != value.strip()
        or len(normalized) > maximum
        or not normalized.isprintable()
    ):
        raise ValueError(f"Loopdy Link {field} is invalid")
    return normalized


def _activity_detail(value: Any, field: str, maximum: int) -> str:
    if (
        not isinstance(value, str)
        or not value
        or len(value) > maximum
        or any(not character.isprintable() and character not in "\n\t" for character in value)
    ):
        raise ValueError(f"Loopdy Link {field} is invalid")
    return value


def _picker_identifier(value: Any, field: str, minimum: int, maximum: int) -> str:
    if (
        not isinstance(value, str)
        or not minimum <= len(value) <= maximum
        or value != value.strip()
        or any(character.isspace() or not character.isprintable() for character in value)
    ):
        raise ValueError(f"Loopdy Link {field} is invalid")
    return value


def _text(value: Any, field: str, maximum: int) -> str:
    if not isinstance(value, str) or not value or len(value) > maximum or "\x00" in value:
        raise ValueError(f"Loopdy Link {field} is invalid")
    return value


def _positive(value: Any, field: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 1:
        raise ValueError(f"Loopdy Link {field} is invalid")
    return value


def _nonnegative(value: Any, field: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise ValueError(f"Loopdy Link {field} is invalid")
    return value


def _decode_b64url(value: str) -> bytes:
    try:
        decoded = base64.b64decode(
            value + "=" * (-len(value) % 4), altchars=b"-_", validate=True
        )
    except (ValueError, UnicodeEncodeError) as error:
        raise ValueError("Loopdy Link base64url is invalid") from error
    if base64.urlsafe_b64encode(decoded).decode("ascii").rstrip("=") != value:
        raise ValueError("Loopdy Link base64url is invalid")
    return decoded


def _b64url(value: Any, field: str, expected_length: int) -> str:
    encoded = _opaque(value, field, 1, 2_048)
    if len(_decode_b64url(encoded)) != expected_length:
        raise ValueError(f"Loopdy Link {field} is invalid")
    return encoded
