"""Legacy relay device/configuration compatibility and revocation tombstones."""

from __future__ import annotations

import hmac
import sqlite3
import time
from typing import Any, Iterable, Mapping
from .store_values import (
    _LEGACY_RELAY_PROVIDER_CONFLICT,
    _identifier,
    _json,
    _normalized_body_digest,
    _positive_integer,
    _positive_revision,
    _protocol_identifier,
    _required_text,
    _text,
)


class RelayDeviceStore:
    def register_relay_device(
        self,
        *,
        device_id: str,
        recipient_public_key: str,
        recipient_key_id: str,
        revision: int,
        lease_expires: int,
        normalized_body: Mapping[str, Any],
        token_environment: str = "production",
        label: str = "",
        groups: Iterable[str] = (),
        preferences: Mapping[str, Any] | None = None,
        now: int | None = None,
        expected_relay_generation: int | None = None,
        terminal_claim_token: str = "",
        terminal_request_digest: str = "",
    ) -> dict[str, Any]:
        current_time = int(time.time()) if now is None else _positive_integer(now, "now")
        normalized_revision = _positive_revision(revision)
        normalized_lease = _positive_integer(lease_expires, "lease_expires")
        if normalized_lease <= current_time or normalized_lease - current_time > 2_592_000:
            raise ValueError("Relay registration lease must be positive and at most 30 days")
        device = _protocol_identifier(device_id, "device_id")
        public_key = _required_text(recipient_public_key, "recipient_public_key", 100)
        recipient_id = _required_text(recipient_key_id, "recipient_key_id", 64)
        digest = _normalized_body_digest(normalized_body)
        normalized_groups = sorted({str(value).strip() for value in groups if str(value).strip()})
        normalized_preferences = None if preferences is None else dict(preferences)
        environment = str(token_environment or "").strip().lower()
        if environment not in {"production", "sandbox"}:
            raise ValueError("Relay token environment must be production or sandbox")
        has_terminal_claim = bool(terminal_claim_token or terminal_request_digest)
        if has_terminal_claim and not (terminal_claim_token and terminal_request_digest):
            raise ValueError("Terminal relay registration claim is incomplete")
        claim_token = (
            _required_text(terminal_claim_token, "terminal_claim_token", 180)
            if has_terminal_claim else ""
        )
        claim_digest = (
            _required_text(terminal_request_digest, "terminal_request_digest", 64)
            if has_terminal_claim else ""
        )
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            relay_generation = self._metadata_integer(connection, "relay_config_generation", 0)
            self._assert_relay_generation(connection, expected_relay_generation, relay_generation)
            if has_terminal_claim:
                claimed = connection.execute(
                    "SELECT 1 FROM pending_relay_operations WHERE operation='register_device' "
                    "AND device_id=? AND terminal=1 AND response_json<>'' AND last_error=? "
                    "AND claim_token=? AND request_digest=? AND relay_generation=? "
                    "AND claim_expires>? LIMIT 1",
                    (
                        device,
                        _LEGACY_RELAY_PROVIDER_CONFLICT,
                        claim_token,
                        claim_digest,
                        relay_generation,
                        current_time,
                    ),
                ).fetchone()
                if claimed is None:
                    raise ValueError("Terminal relay registration claim is no longer active")

            def consume_terminal_claim() -> None:
                if not has_terminal_claim:
                    return
                cursor = connection.execute(
                    "DELETE FROM pending_relay_operations WHERE operation='register_device' "
                    "AND device_id=? AND terminal=1 AND response_json<>'' AND last_error=? "
                    "AND claim_token=? AND request_digest=? AND relay_generation=? "
                    "AND claim_expires>?",
                    (
                        device,
                        _LEGACY_RELAY_PROVIDER_CONFLICT,
                        claim_token,
                        claim_digest,
                        relay_generation,
                        current_time,
                    ),
                )
                if cursor.rowcount != 1:
                    raise ValueError("Terminal relay registration claim is no longer active")

            existing = connection.execute(
                "SELECT provider, revision, normalized_body_digest, revoked_at, relay_generation "
                "FROM devices WHERE device_id=?",
                (device,),
            ).fetchone()
            if existing is not None:
                previous_revision = int(existing["revision"])
                if existing["revoked_at"] is not None and normalized_revision <= previous_revision:
                    raise ValueError("A tombstoned relay device requires a higher revision")
                if normalized_revision < previous_revision:
                    raise ValueError("Relay device revision cannot decrease")
                if normalized_revision == previous_revision:
                    if hmac.compare_digest(str(existing["normalized_body_digest"]), digest):
                        if int(existing["relay_generation"]) != relay_generation:
                            connection.execute(
                                "UPDATE devices SET relay_generation=?, updated_at=? WHERE device_id=?",
                                (relay_generation, current_time, device),
                            )
                            consume_terminal_claim()
                            return {"changed": True, "revision": normalized_revision}
                        consume_terminal_claim()
                        return {"changed": False, "revision": normalized_revision}
                    raise ValueError("Relay registration idempotency conflict")
                if existing["provider"] != "relay":
                    connection.execute(
                        "UPDATE event_deliveries SET status='failed', failure='relay_target_changed', "
                        "relay_request_body_json='', claim_token='', claim_expires=0, next_attempt_at=0 "
                        "WHERE provider IN ('managed', 'direct') AND device_id=? AND status='queued'",
                        (device,),
                    )
                    connection.execute(
                        "DELETE FROM provider_receipts WHERE provider IN ('managed', 'direct') "
                        "AND device_id=? AND status='pending'",
                        (device,),
                    )
                connection.execute(
                    "UPDATE event_deliveries SET status='failed', failure='relay_target_changed', "
                    "relay_request_body_json='' WHERE provider='relay' AND status='queued' "
                    "AND device_id=?",
                    (device,),
                )
                # A new non-revoking device registration supersedes every
                # in-flight Live Activity registration addressed to that
                # device.  The journal key is the activity ID, so resolve
                # ownership from the frozen request body before allowing the
                # registration revision to commit.
                connection.execute(
                    "UPDATE pending_relay_operations SET terminal=1, "
                    "last_error='relay_target_changed', claim_token='', "
                    "claim_expires=0, next_attempt_at=0, updated_at=?, "
                    "row_version=row_version+1 WHERE terminal=0 "
                    "AND operation='register_live_activity' AND json_valid(body_json) "
                    "AND json_extract(body_json, '$.device_id')=?",
                    (current_time, device),
                )
                connection.execute(
                    "DELETE FROM pending_relay_live_activity_updates "
                    "WHERE activity_id IN (SELECT activity_id FROM relay_live_activities WHERE device_id=?)",
                    (device,),
                )
            connection.execute(
                """
                INSERT INTO devices (
                    device_id, endpoint_id, provider, token_environment, label,
                    groups_json, preferences_json, created_at, updated_at, revoked_at,
                    recipient_public_key, recipient_key_id, revision, lease_expires,
                    normalized_body_digest, sender_key_revision,
                    acknowledged_sender_key_ids_json, sender_ack_body_digest, relay_generation
                ) VALUES (?, ?, 'relay', ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, 0, '[]', '', ?)
                ON CONFLICT(device_id) DO UPDATE SET
                    endpoint_id=excluded.endpoint_id,
                    provider='relay',
                    token_environment=excluded.token_environment,
                    label=excluded.label,
                    groups_json=excluded.groups_json,
                    preferences_json=CASE WHEN ? IS NULL THEN devices.preferences_json ELSE excluded.preferences_json END,
                    updated_at=excluded.updated_at,
                    revoked_at=NULL,
                    recipient_public_key=excluded.recipient_public_key,
                    recipient_key_id=excluded.recipient_key_id,
                    revision=excluded.revision,
                    lease_expires=excluded.lease_expires,
                    normalized_body_digest=excluded.normalized_body_digest,
                    sender_key_revision=CASE
                        WHEN devices.recipient_key_id=excluded.recipient_key_id
                         AND devices.recipient_public_key=excluded.recipient_public_key
                        THEN devices.sender_key_revision ELSE 0 END,
                    acknowledged_sender_key_ids_json=CASE
                        WHEN devices.recipient_key_id=excluded.recipient_key_id
                         AND devices.recipient_public_key=excluded.recipient_public_key
                        THEN devices.acknowledged_sender_key_ids_json ELSE '[]' END,
                    sender_ack_body_digest=CASE
                        WHEN devices.recipient_key_id=excluded.recipient_key_id
                         AND devices.recipient_public_key=excluded.recipient_public_key
                        THEN devices.sender_ack_body_digest ELSE '' END,
                    relay_generation=excluded.relay_generation
                """,
                (
                    device,
                    recipient_id,
                    environment,
                    _text(label, 120),
                    _json(normalized_groups),
                    _json(normalized_preferences if normalized_preferences is not None else {}),
                    current_time,
                    current_time,
                    public_key,
                    recipient_id,
                    normalized_revision,
                    normalized_lease,
                    digest,
                    relay_generation,
                    _json(normalized_preferences) if normalized_preferences is not None else None,
                ),
            )
            consume_terminal_claim()
        return {"changed": True, "revision": normalized_revision}

    def acknowledge_relay_sender_keys(
        self,
        *,
        device_id: str,
        revision: int,
        sender_key_revision: int,
        acknowledged_sender_key_ids: Iterable[str],
        normalized_body: Mapping[str, Any],
        now: int | None = None,
        expected_relay_generation: int | None = None,
    ) -> dict[str, Any]:
        current_time = int(time.time()) if now is None else _positive_integer(now, "now")
        device = _protocol_identifier(device_id, "device_id")
        normalized_revision = _positive_revision(revision)
        normalized_sender_revision = _positive_revision(sender_key_revision)
        key_ids = list(acknowledged_sender_key_ids)
        if not 1 <= len(key_ids) <= 2 or len(set(key_ids)) != len(key_ids):
            raise ValueError("Relay sender-key acknowledgement must contain one or two unique keys")
        if any(type(value) is not str for value in key_ids):
            raise ValueError("Relay sender-key acknowledgement must contain string key IDs")
        key_ids = sorted(_required_text(value, "sender_key_id", 64) for value in key_ids)
        digest = _normalized_body_digest(normalized_body)
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            relay_generation = self._metadata_integer(connection, "relay_config_generation", 0)
            self._assert_relay_generation(connection, expected_relay_generation, relay_generation)
            existing = connection.execute(
                "SELECT provider, revision, sender_ack_body_digest, revoked_at "
                "FROM devices WHERE device_id=?",
                (device,),
            ).fetchone()
            if existing is None or existing["provider"] != "relay" or existing["revoked_at"] is not None:
                raise ValueError("Unknown or revoked relay device")
            previous_revision = int(existing["revision"])
            if normalized_revision < previous_revision:
                raise ValueError("Relay device revision cannot decrease")
            if normalized_revision == previous_revision:
                if hmac.compare_digest(str(existing["sender_ack_body_digest"]), digest):
                    return {"changed": False, "revision": normalized_revision}
                raise ValueError("Relay sender-key acknowledgement idempotency conflict")
            connection.execute(
                "UPDATE devices SET revision=?, sender_key_revision=?, "
                "acknowledged_sender_key_ids_json=?, sender_ack_body_digest=?, updated_at=? "
                "WHERE device_id=? AND provider='relay' AND revoked_at IS NULL",
                (
                    normalized_revision,
                    normalized_sender_revision,
                    _json(key_ids),
                    digest,
                    current_time,
                    device,
                ),
            )
        return {"changed": True, "revision": normalized_revision}

    def revoke_relay_device(
        self,
        *,
        device_id: str,
        revision: int,
        normalized_body: Mapping[str, Any],
        now: int | None = None,
        expected_relay_generation: int | None = None,
    ) -> dict[str, Any]:
        current_time = int(time.time()) if now is None else _positive_integer(now, "now")
        device = _protocol_identifier(device_id, "device_id")
        normalized_revision = _positive_revision(revision)
        digest = _normalized_body_digest(normalized_body)
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            relay_generation = self._metadata_integer(connection, "relay_config_generation", 0)
            self._assert_relay_generation(connection, expected_relay_generation, relay_generation)
            existing = connection.execute(
                "SELECT provider, revision, normalized_body_digest, revoked_at "
                "FROM devices WHERE device_id=?",
                (device,),
            ).fetchone()
            if existing is None or existing["provider"] != "relay":
                raise ValueError("Unknown relay device")
            previous_revision = int(existing["revision"])
            if normalized_revision < previous_revision:
                raise ValueError("Relay device revision cannot decrease")
            if normalized_revision == previous_revision:
                if existing["revoked_at"] is not None and hmac.compare_digest(
                    str(existing["normalized_body_digest"]), digest
                ):
                    return {"changed": False, "revision": normalized_revision}
                raise ValueError("Relay revocation idempotency conflict")
            connection.execute(
                "UPDATE devices SET revision=?, normalized_body_digest=?, revoked_at=?, updated_at=? "
                "WHERE device_id=? AND provider='relay'",
                (normalized_revision, digest, current_time, current_time, device),
            )
            self._cancel_relay_device_work(connection, device, current_time)
        return {"changed": True, "revision": normalized_revision}

    def save_relay_config(self, config: Mapping[str, Any]) -> None:
        del config
        raise ValueError("Legacy Cloudflare relay configuration is retired")

    def load_relay_config(self) -> dict[str, str] | None:
        return None

    def clear_relay_config(self) -> None:
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            connection.execute("DELETE FROM metadata WHERE key='relay_config_v1'")
            connection.execute(
                "UPDATE event_deliveries SET status='failed', failure='relay_target_changed', "
                "relay_request_body_json='', claim_token='', claim_expires=0, next_attempt_at=0 "
                "WHERE provider='relay' AND status='queued'"
            )
            connection.execute("DELETE FROM pending_relay_live_activity_updates")
            connection.execute("DELETE FROM pending_relay_operations")
            generation = self._metadata_integer(connection, "relay_config_generation", 0) + 1
            connection.execute(
                "INSERT INTO metadata(key, value) VALUES ('relay_config_generation', ?) "
                "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                (str(generation),),
            )
            connection.execute(
                "INSERT INTO metadata(key, value) VALUES ('relay_config_state', 'disabled') "
                "ON CONFLICT(key) DO UPDATE SET value='disabled'"
            )

    def relay_config_generation(self) -> int:
        with self._connect() as connection:
            return self._metadata_integer(connection, "relay_config_generation", 0)

    def relay_config_enabled(self) -> bool:
        return False

    def _cancel_relay_device_work(
        self,
        connection: sqlite3.Connection,
        device_id: str,
        now: int,
    ) -> None:
        identifier = _identifier(device_id, "device_id")
        connection.execute(
            "UPDATE event_deliveries SET status='failed', failure='relay_target_changed', "
            "relay_request_body_json='', claim_token='', claim_expires=0, next_attempt_at=0 "
            "WHERE provider='relay' AND device_id=? AND status='queued'",
            (identifier,),
        )
        connection.execute(
            "DELETE FROM pending_relay_live_activity_updates WHERE device_id=?",
            (identifier,),
        )
        connection.execute(
            "UPDATE pending_relay_operations SET terminal=1, last_error='relay_target_changed', "
            "claim_token='', claim_expires=0, next_attempt_at=0, updated_at=?, row_version=row_version+1 "
            "WHERE terminal=0 AND operation NOT IN ('revoke_device', 'device_revoke') "
            "AND (device_id=? OR (json_valid(body_json) AND "
            "json_extract(body_json, '$.device_id')=?) OR "
            "(operation='revoke_live_activity' AND device_id IN ("
            "SELECT activity_id FROM relay_live_activities WHERE device_id=?)))",
            (now, identifier, identifier, identifier),
        )
        connection.execute(
            "UPDATE relay_live_activities SET ended_at=COALESCE(ended_at, ?), "
            "revoked_at=COALESCE(revoked_at, ?), updated_at=? WHERE device_id=? "
            "AND ended_at IS NULL AND revoked_at IS NULL",
            (now, now, now, identifier),
        )

    def revoke_relay_tenant(
        self,
        *,
        clear_config: bool = False,
        expected_relay_generation: int | None = None,
    ) -> None:
        """Locally tombstone relay state after a verified tenant operation."""
        now = int(time.time())
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            current_generation = self._metadata_integer(connection, "relay_config_generation", 0)
            self._assert_relay_generation(connection, expected_relay_generation, current_generation)
            generation = current_generation + 1
            if clear_config:
                connection.execute("DELETE FROM event_deliveries WHERE provider='relay'")
                connection.execute("DELETE FROM provider_receipts WHERE provider='relay'")
                connection.execute("DELETE FROM pending_relay_live_activity_updates")
                connection.execute("DELETE FROM pending_relay_operations")
                connection.execute("DELETE FROM relay_live_activities")
                connection.execute("DELETE FROM devices WHERE provider='relay'")
                connection.execute("DELETE FROM metadata WHERE key='relay_config_v1'")
            else:
                connection.execute(
                    "UPDATE event_deliveries SET status='failed', failure='relay_target_changed', "
                    "relay_request_body_json='' WHERE provider='relay' AND status='queued'"
                )
                connection.execute(
                    "UPDATE devices SET revoked_at=COALESCE(revoked_at, ?), "
                    "acknowledged_sender_key_ids_json='[]', sender_ack_body_digest='', "
                    "updated_at=?, relay_generation=? WHERE provider='relay'",
                    (now, now, generation),
                )
                connection.execute(
                    "UPDATE relay_live_activities SET ended_at=COALESCE(ended_at, ?), "
                    "revoked_at=COALESCE(revoked_at, ?), updated_at=?",
                    (now, now, now),
                )
                connection.execute("DELETE FROM pending_relay_live_activity_updates")
                connection.execute("DELETE FROM pending_relay_operations")
            connection.execute(
                "INSERT INTO metadata(key, value) VALUES ('relay_config_generation', ?) "
                "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                (str(generation),),
            )
            connection.execute(
                "INSERT INTO metadata(key, value) VALUES ('relay_config_state', 'disabled') "
                "ON CONFLICT(key) DO UPDATE SET value='disabled'"
            )
