"""Retained paired transport envelopes, uploads, messages and relay readiness."""
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any

from .protocol_values import (
    MAX_ATTACHMENT_BYTES, MAX_MESSAGE_ATTACHMENT_BYTES,
    MAX_ATTACHMENT_CHUNK_BYTES, MAX_ATTACHMENT_CHUNKS,
    _b64url, _decode_b64url, _label, _nonnegative, _opaque,
    _positive, _session_coordinate, _text, _validate_envelope,
)

def parse_direct_enrollment(payload: dict[str, Any]) -> dict[str, Any]:
    """Strict application envelope; proof verification is authority-owned."""
    if (type(payload) is not dict or set(payload) != {"version", "type", "enrollment"}
            or type(payload["version"]) is not int or payload["version"] != 1
            or payload["type"] != "direct.enroll"):
        raise ValueError("direct enrollment envelope is invalid")
    enrollment = payload["enrollment"]
    fields = {"version", "exchangeId", "phoneNonce", "phonePublicKey", "phoneProof"}
    if (type(enrollment) is not dict or set(enrollment) != fields
            or type(enrollment["version"]) is not int or enrollment["version"] != 1
            or any(not isinstance(enrollment[key], str) or not 1 <= len(enrollment[key]) <= 512
                   for key in fields - {"version"})):
        raise ValueError("direct enrollment request is invalid")
    return dict(enrollment)


_MIME_TYPE = re.compile(r"^[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+$")


MAX_ENCRYPTED_FRAME_CHARACTERS = 4_000_000


@dataclass(frozen=True)
class EncryptedFrame:
    frame_id: str
    sender_device_id: str
    sender_epoch: int
    sequence: int
    ack: int
    ciphertext: str
    target_device_id: str | None = None
    delivery_class: str | None = None

    def wire_value(self) -> dict[str, Any]:
        value = {
            "version": 1,
            "type": "frame",
            "id": self.frame_id,
            "senderDeviceId": self.sender_device_id,
            "senderEpoch": self.sender_epoch,
            "sequence": self.sequence,
            "ack": self.ack,
            "ciphertext": self.ciphertext,
        }
        if self.target_device_id is not None:
            value["targetDeviceId"] = self.target_device_id
        if self.delivery_class is not None:
            if self.delivery_class != "presentation":
                raise ValueError("frame delivery class is invalid")
            value["deliveryClass"] = self.delivery_class
        return value


@dataclass(frozen=True)
class AttachmentReference:
    attachment_id: str
    file_name: str
    mime_type: str
    total_bytes: int
    sha256: str


@dataclass(frozen=True)
class AttachmentChunk:
    upload_id: str
    session_id: str
    agent_id: str
    reference: AttachmentReference
    index: int
    count: int
    data: bytes
    sent_at: int


@dataclass(frozen=True)
class UserMessage:
    message_id: str
    session_id: str
    agent_id: str
    actor_id: str
    actor_name: str
    device_name: str
    text: str
    sent_at: int
    attachments: tuple[AttachmentReference, ...] = ()
    behavior: str | None = None


class ExpiredHostRelayEnrollment(ValueError):
    """A valid host-relay enrollment whose lease cannot be replayed."""


@dataclass(frozen=True)
class RelayReady:
    device_id: str
    enrollment_revision: int
    acknowledgement_revision: int
    lease_expires: int
    recipient_public_key: str
    recipient_key_id: str
    sender_key_revision: int
    acknowledged_sender_key_ids: tuple[str, ...]
    environment: str
    topic: str
    device_name: str
    sent_at: int
    scope: str = "link_wake"

    def wire_value(self) -> dict[str, Any]:
        value = {
            "version": 1,
            "type": "relay.ready",
            "deviceId": self.device_id,
            "enrollmentRevision": self.enrollment_revision,
            "acknowledgementRevision": self.acknowledgement_revision,
            "leaseExpires": self.lease_expires,
            "recipientPublicKey": self.recipient_public_key,
            "recipientKeyId": self.recipient_key_id,
            "senderKeyRevision": self.sender_key_revision,
            "acknowledgedSenderKeyIds": list(self.acknowledged_sender_key_ids),
            "environment": self.environment,
            "topic": self.topic,
            "deviceName": self.device_name,
            "sentAt": self.sent_at,
        }
        if self.scope != "link_wake":
            value["scope"] = self.scope
        return value


def parse_encrypted_frame(encoded: str) -> EncryptedFrame:
    if not isinstance(encoded, str) or len(encoded) > MAX_ENCRYPTED_FRAME_CHARACTERS:
        raise ValueError("Loopdy Link frame is invalid")
    try:
        value = json.loads(encoded)
    except (TypeError, json.JSONDecodeError) as exc:
        raise ValueError("Loopdy Link frame is invalid") from exc
    if (
        not isinstance(value, dict)
        or set(value) - {"targetDeviceId", "deliveryClass"} != {
            "version", "type", "id", "senderDeviceId", "senderEpoch", "sequence", "ack", "ciphertext"}
        or value.get("version") != 1
        or value.get("type") != "frame"
    ):
        raise ValueError("Loopdy Link frame is invalid")
    delivery_class = value.get("deliveryClass")
    if "deliveryClass" in value and delivery_class != "presentation":
        raise ValueError("Loopdy Link delivery class is invalid")
    target_device_id = value.get("targetDeviceId")
    if target_device_id is not None:
        target_device_id = _opaque(target_device_id, "targetDeviceId", 1, 96)
    return EncryptedFrame(
        frame_id=_opaque(value.get("id"), "id", 16, 128),
        sender_device_id=_opaque(
            value.get("senderDeviceId"), "senderDeviceId", 1, 96
        ),
        sender_epoch=_positive(value.get("senderEpoch"), "senderEpoch"),
        sequence=_positive(value.get("sequence"), "sequence"),
        ack=_nonnegative(value.get("ack"), "ack"),
        ciphertext=_opaque(
            value.get("ciphertext"),
            "ciphertext",
            16,
            MAX_ENCRYPTED_FRAME_CHARACTERS,
        ),
        target_device_id=target_device_id,
        delivery_class=delivery_class,
    )


def parse_user_message(value: dict[str, Any]) -> UserMessage:
    if not isinstance(value, dict) or value.get("version") != 1 or value.get("type") != "user.message":
        raise ValueError("Loopdy Link user message is invalid")
    raw_attachments = value.get("attachments", [])
    if not isinstance(raw_attachments, list) or len(raw_attachments) > 10:
        raise ValueError("Loopdy Link user message attachments are invalid")
    attachments = tuple(_attachment_reference(item) for item in raw_attachments)
    if sum(item.total_bytes for item in attachments) > MAX_MESSAGE_ATTACHMENT_BYTES:
        raise ValueError("Loopdy Link user message attachments are invalid")
    behavior = value.get("behavior")
    if behavior is not None and (
        not isinstance(behavior, str)
        or isinstance(behavior, bool)
        or behavior not in {"steer", "queue", "interrupt"}
    ):
        raise ValueError("Loopdy Link user message behavior is invalid")
    return UserMessage(
        message_id=_opaque(value.get("messageId"), "messageId", 16, 128),
        session_id=_session_coordinate(value.get("sessionId")),
        agent_id=_opaque(value.get("agentId"), "agentId", 1, 96),
        actor_id=_opaque(value.get("actorId"), "actorId", 1, 96),
        actor_name=_label(value.get("actorName"), "actorName", 80),
        device_name=_label(value.get("deviceName"), "deviceName", 96),
        text=_text(value.get("text"), "text", 100_000),
        sent_at=_positive(value.get("sentAt"), "sentAt"),
        attachments=attachments,
        behavior=behavior,
    )


def parse_attachment_chunk(value: dict[str, Any]) -> AttachmentChunk:
    expected = {
        "version",
        "type",
        "uploadId",
        "sessionId",
        "agentId",
        "attachmentId",
        "fileName",
        "mimeType",
        "totalBytes",
        "sha256",
        "index",
        "count",
        "data",
        "sentAt",
    }
    _validate_envelope(
        value, expected, "attachment.chunk", "Loopdy Link attachment chunk is invalid",
        strict_version=False,
    )
    reference = _attachment_reference(value)
    index = _nonnegative(value.get("index"), "index")
    count = _positive(value.get("count"), "count")
    if count > MAX_ATTACHMENT_CHUNKS or index >= count:
        raise ValueError("Loopdy Link attachment chunk coordinate is invalid")
    data = _decode_b64url(_opaque(value.get("data"), "data", 1, 180_000))
    if not data or len(data) > MAX_ATTACHMENT_CHUNK_BYTES:
        raise ValueError("Loopdy Link attachment chunk data is invalid")
    if index < count - 1 and len(data) != MAX_ATTACHMENT_CHUNK_BYTES:
        raise ValueError("Loopdy Link attachment chunk size is invalid")
    return AttachmentChunk(
        upload_id=_opaque(value.get("uploadId"), "uploadId", 16, 128),
        session_id=_session_coordinate(value.get("sessionId")),
        agent_id=_opaque(value.get("agentId"), "agentId", 1, 96),
        reference=reference,
        index=index,
        count=count,
        data=data,
        sent_at=_positive(value.get("sentAt"), "sentAt"),
    )


def _attachment_reference(value: Any) -> AttachmentReference:
    if not isinstance(value, dict):
        raise ValueError("Loopdy Link attachment reference is invalid")
    file_name = value.get("fileName")
    if (
        not isinstance(file_name, str)
        or not file_name
        or len(file_name) > 180
        or file_name != file_name.strip()
        or file_name in {".", ".."}
        or "/" in file_name
        or "\\" in file_name
        or not file_name.isprintable()
    ):
        raise ValueError("Loopdy Link attachment file name is invalid")
    mime_type = value.get("mimeType")
    if not isinstance(mime_type, str) or not _MIME_TYPE.fullmatch(mime_type):
        raise ValueError("Loopdy Link attachment MIME type is invalid")
    total_bytes = _positive(value.get("totalBytes"), "totalBytes")
    if total_bytes > MAX_ATTACHMENT_BYTES:
        raise ValueError("Loopdy Link attachment size is invalid")
    return AttachmentReference(
        attachment_id=_opaque(value.get("attachmentId"), "attachmentId", 16, 128),
        file_name=file_name,
        mime_type=mime_type,
        total_bytes=total_bytes,
        sha256=_b64url(value.get("sha256"), "sha256", 32),
    )


def parse_relay_ready(value: dict[str, Any]) -> RelayReady:
    expected = {
        "version",
        "type",
        "deviceId",
        "enrollmentRevision",
        "acknowledgementRevision",
        "leaseExpires",
        "recipientPublicKey",
        "recipientKeyId",
        "senderKeyRevision",
        "acknowledgedSenderKeyIds",
        "environment",
        "topic",
        "deviceName",
        "sentAt",
    }
    _validate_envelope(
        value, expected, "relay.ready", "Loopdy Link relay readiness is invalid",
        strict_version=False, optional={"scope"},
    )
    scope = value.get("scope", "link_wake")
    if scope not in {"link_wake", "host_relay"}:
        raise ValueError("Loopdy Link relay readiness scope is invalid")
    enrollment = _positive(value.get("enrollmentRevision"), "enrollmentRevision")
    acknowledgement = _positive(
        value.get("acknowledgementRevision"), "acknowledgementRevision"
    )
    sent_at = _positive(value.get("sentAt"), "sentAt")
    lease_expires = _positive(value.get("leaseExpires"), "leaseExpires")
    if acknowledgement != enrollment + 1 or not sent_at < lease_expires <= sent_at + 2_592_000:
        raise ValueError("Loopdy Link relay readiness revisions are invalid")
    raw_ids = value.get("acknowledgedSenderKeyIds")
    if not isinstance(raw_ids, list):
        raise ValueError("Loopdy Link relay sender keys must be an array")
    if not 1 <= len(raw_ids) <= 2:
        raise ValueError("Loopdy Link relay sender-key acknowledgement count is invalid")
    if len(set(raw_ids)) != len(raw_ids):
        raise ValueError("Loopdy Link relay sender keys must be unique")
    sender_ids = tuple(_b64url(item, "senderKeyId", 32) for item in raw_ids)
    recipient_public_key = _b64url(
        value.get("recipientPublicKey"), "recipientPublicKey", 65
    )
    if _decode_b64url(recipient_public_key)[0] != 4:
        raise ValueError("Loopdy Link relay recipient key is invalid")
    environment = value.get("environment")
    topic = value.get("topic")
    if environment not in {"production", "sandbox"}:
        raise ValueError("Loopdy Link relay environment is invalid")
    if (
        not isinstance(topic, str)
        or len(topic) > 255
        or re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", topic) is None
    ):
        raise ValueError("Loopdy Link relay topic is invalid")
    return RelayReady(
        device_id=_opaque(value.get("deviceId"), "deviceId", 1, 96),
        enrollment_revision=enrollment,
        acknowledgement_revision=acknowledgement,
        lease_expires=lease_expires,
        recipient_public_key=recipient_public_key,
        recipient_key_id=_b64url(value.get("recipientKeyId"), "recipientKeyId", 32),
        sender_key_revision=_positive(value.get("senderKeyRevision"), "senderKeyRevision"),
        acknowledged_sender_key_ids=sender_ids,
        environment=environment,
        topic=topic,
        device_name=_label(value.get("deviceName"), "deviceName", 96),
        sent_at=sent_at,
        scope=scope,
    )


def parse_backpressure(value: Any) -> tuple[str, int, int]:
    expected = {"version", "type", "id", "sequence", "retryAfterMs", "reason"}
    _validate_envelope(
        value, expected, "backpressure", "Loopdy Link backpressure is invalid",
        strict_version=True,
    )
    if value.get("reason") != "storage_limit":
        raise ValueError("Loopdy Link backpressure is invalid")
    frame_id = _opaque(value.get("id"), "id", 16, 128)
    sequence = _positive(value.get("sequence"), "sequence")
    delay = _positive(value.get("retryAfterMs"), "retryAfterMs")
    if not 100 <= delay <= 30_000:
        raise ValueError("Loopdy Link backpressure delay is invalid")
    return frame_id, sequence, delay
