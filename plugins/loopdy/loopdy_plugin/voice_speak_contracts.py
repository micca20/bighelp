"""Speech request validation and bounded synthesized-audio wire responses."""
from __future__ import annotations

import base64
import hashlib
import math
from dataclasses import dataclass
from typing import Any

from .protocol_values import (
    _label, _opaque, _positive, _session_coordinate, _text, _validate_envelope,
)

@dataclass(frozen=True)
class VoiceSpeakRequest:
    request_id: str
    session_id: str
    agent_id: str
    text: str
    speed: float
    sent_at: int

    def wire_value(self) -> dict[str, Any]:
        return {
            "version": 1,
            "type": "voice.speak.request",
            "requestId": self.request_id,
            "sessionId": self.session_id,
            "agentId": self.agent_id,
            "text": self.text,
            "speed": self.speed,
            "sentAt": self.sent_at,
        }


def parse_voice_speak_request(value: dict[str, Any]) -> VoiceSpeakRequest:
    expected = {
        "version",
        "type",
        "requestId",
        "sessionId",
        "agentId",
        "text",
        "speed",
        "sentAt",
    }
    _validate_envelope(
        value, expected, "voice.speak.request", "Loopdy Link voice request is invalid",
        strict_version=False,
    )
    speed = value.get("speed")
    if (
        not isinstance(speed, (int, float))
        or isinstance(speed, bool)
        or not math.isfinite(float(speed))
        or not 0.25 <= float(speed) <= 4.0
    ):
        raise ValueError("Loopdy Link voice speed is invalid")
    return VoiceSpeakRequest(
        request_id=_opaque(value.get("requestId"), "requestId", 16, 128),
        session_id=_session_coordinate(value.get("sessionId")),
        agent_id=_opaque(value.get("agentId"), "agentId", 1, 96),
        text=_text(value.get("text"), "text", 20_000),
        speed=float(speed),
        sent_at=_positive(value.get("sentAt"), "sentAt"),
    )


def voice_audio_chunks(
    *,
    request: VoiceSpeakRequest,
    audio: bytes,
    mime_type: str,
    provider: str,
    sent_at: int,
) -> list[dict[str, Any]]:
    if not isinstance(audio, bytes) or not audio or len(audio) > 8 * 1024 * 1024:
        raise ValueError("Loopdy Link voice audio size is invalid")
    if mime_type not in {"audio/mpeg", "audio/ogg", "audio/wav", "audio/flac"}:
        raise ValueError("Loopdy Link voice MIME type is invalid")
    provider_name = _label(provider, "provider", 80)
    timestamp = _positive(sent_at, "sentAt")
    chunk_size = 90 * 1024
    count = (len(audio) + chunk_size - 1) // chunk_size
    if not 1 <= count <= 92:
        raise ValueError("Loopdy Link voice chunk count is invalid")
    digest = base64.urlsafe_b64encode(hashlib.sha256(audio).digest()).decode("ascii").rstrip("=")
    chunks: list[dict[str, Any]] = []
    for index in range(count):
        piece = audio[index * chunk_size : (index + 1) * chunk_size]
        chunks.append(
            {
                "version": 1,
                "type": "voice.speak.chunk",
                "requestId": request.request_id,
                "sessionId": request.session_id,
                "agentId": request.agent_id,
                "index": index,
                "count": count,
                "mimeType": mime_type,
                "provider": provider_name,
                "totalBytes": len(audio),
                "sha256": digest,
                "audio": base64.urlsafe_b64encode(piece).decode("ascii").rstrip("="),
                "sentAt": timestamp,
            }
        )
    return chunks


def voice_speak_error(
    *, request: VoiceSpeakRequest, code: str, message: str, sent_at: int
) -> dict[str, Any]:
    if code not in {"unavailable", "synthesis_failed", "audio_too_large"}:
        raise ValueError("Loopdy Link voice error code is invalid")
    return {
        "version": 1,
        "type": "voice.speak.error",
        "requestId": request.request_id,
        "sessionId": request.session_id,
        "agentId": request.agent_id,
        "code": code,
        "message": _label(message, "message", 160),
        "sentAt": _positive(sent_at, "sentAt"),
    }
