"""Legacy relay activity journal compatibility. Not a production delivery route."""

from __future__ import annotations

import hmac
import time
from typing import Any, Mapping
from .store_values import (
    _identifier,
    _json,
    _normalized_body_digest,
    _positive_integer,
    _positive_revision,
    _protocol_identifier,
    _required_text,
    _text,
)


class RelayActivityStore:
    def has_pending_relay_live_activity_updates(self) -> bool:
        with self._connect() as connection:
            return connection.execute(
                "SELECT 1 FROM pending_relay_live_activity_updates WHERE terminal=0 LIMIT 1"
            ).fetchone() is not None

    def register_relay_live_activity(
        self,
        *,
        activity_id: str,
        device_id: str,
        session_ref: str,
        revision: int,
        timestamp: int,
        lease_expires: int,
        normalized_body: Mapping[str, Any],
        expected_relay_generation: int | None = None,
    ) -> dict[str, Any]:
        activity = _protocol_identifier(activity_id, "activity_id")
        device = _protocol_identifier(device_id, "device_id")
        normalized_revision = _positive_revision(revision)
        watermark = _positive_integer(timestamp, "timestamp")
        normalized_expires = _positive_integer(lease_expires, "lease_expires")
        if watermark <= 0 or normalized_expires <= watermark or normalized_expires - watermark > 28_800:
            raise ValueError("Relay Live Activity registration lease exceeds eight hours")
        digest = _normalized_body_digest(normalized_body)
        now = int(time.time())
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            relay_generation = self._metadata_integer(connection, "relay_config_generation", 0)
            self._assert_relay_generation(connection, expected_relay_generation, relay_generation)
            existing = connection.execute(
                "SELECT revision, source_timestamp, normalized_body_digest, revoked_at "
                "FROM relay_live_activities WHERE activity_id=?",
                (activity,),
            ).fetchone()
            if existing is not None:
                previous_revision = int(existing["revision"])
                if existing["revoked_at"] is not None and normalized_revision <= previous_revision:
                    raise ValueError("A revoked Live Activity requires a higher revision")
                if normalized_revision < previous_revision:
                    raise ValueError("Relay Live Activity revision cannot decrease")
                if normalized_revision == previous_revision:
                    if hmac.compare_digest(str(existing["normalized_body_digest"]), digest):
                        return {"changed": False, "revision": normalized_revision}
                    raise ValueError("Relay Live Activity idempotency conflict")
                if watermark <= int(existing["source_timestamp"]):
                    raise ValueError("Relay Live Activity timestamp must increase")
                connection.execute(
                    "DELETE FROM pending_relay_live_activity_updates WHERE activity_id=?",
                    (activity,),
                )
            connection.execute(
                """
                INSERT INTO relay_live_activities (
                    activity_id, device_id, session_ref, revision, source_timestamp,
                    lease_expires, normalized_body_digest, created_at, updated_at,
                    last_push_timestamp, ended_at, revoked_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL)
                ON CONFLICT(activity_id) DO UPDATE SET
                    device_id=excluded.device_id,
                    session_ref=excluded.session_ref,
                    revision=excluded.revision,
                    source_timestamp=excluded.source_timestamp,
                    lease_expires=excluded.lease_expires,
                    normalized_body_digest=excluded.normalized_body_digest,
                    updated_at=excluded.updated_at,
                    ended_at=NULL,
                    revoked_at=NULL
                """,
                (
                    activity,
                    device,
                    _required_text(session_ref, "session_ref", 100),
                    normalized_revision,
                    watermark,
                    normalized_expires,
                    digest,
                    now,
                    now,
                    watermark,
                ),
            )
        return {"changed": True, "revision": normalized_revision}

    def revoke_relay_live_activity(
        self,
        *,
        activity_id: str,
        revision: int,
        timestamp: int,
        normalized_body: Mapping[str, Any],
        expected_relay_generation: int | None = None,
    ) -> dict[str, Any]:
        activity = _protocol_identifier(activity_id, "activity_id")
        normalized_revision = _positive_revision(revision)
        watermark = _positive_integer(timestamp, "timestamp")
        digest = _normalized_body_digest(normalized_body)
        now = int(time.time())
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            relay_generation = self._metadata_integer(connection, "relay_config_generation", 0)
            self._assert_relay_generation(connection, expected_relay_generation, relay_generation)
            existing = connection.execute(
                "SELECT revision, source_timestamp, normalized_body_digest, revoked_at "
                "FROM relay_live_activities WHERE activity_id=?",
                (activity,),
            ).fetchone()
            if existing is None:
                raise ValueError("Unknown relay Live Activity")
            previous_revision = int(existing["revision"])
            if normalized_revision < previous_revision:
                raise ValueError("Relay Live Activity revision cannot decrease")
            if normalized_revision == previous_revision:
                if existing["revoked_at"] is not None and hmac.compare_digest(
                    str(existing["normalized_body_digest"]), digest
                ):
                    return {"changed": False, "revision": normalized_revision}
                raise ValueError("Relay Live Activity revocation idempotency conflict")
            if watermark <= int(existing["source_timestamp"]):
                raise ValueError("Relay Live Activity timestamp must increase")
            connection.execute(
                "UPDATE relay_live_activities SET revision=?, source_timestamp=?, "
                "normalized_body_digest=?, ended_at=?, revoked_at=?, updated_at=? "
                "WHERE activity_id=?",
                (normalized_revision, watermark, digest, now, now, now, activity),
            )
            connection.execute(
                "DELETE FROM pending_relay_live_activity_updates WHERE activity_id=?",
                (activity,),
            )
        return {"changed": True, "revision": normalized_revision}

    def active_relay_live_activities(
        self,
        session_ref: str,
        *,
        now: int | None = None,
    ) -> list[dict[str, Any]]:
        reference = _required_text(session_ref, "session_ref", 100)
        current_time = int(time.time()) if now is None else _positive_integer(now, "now")
        with self._connect() as connection:
            rows = connection.execute(
                "SELECT activity.* FROM relay_live_activities AS activity "
                "JOIN devices AS device ON device.device_id=activity.device_id "
                "WHERE activity.session_ref=? AND activity.ended_at IS NULL "
                "AND activity.revoked_at IS NULL AND activity.lease_expires>? "
                "AND device.provider='relay' AND device.revoked_at IS NULL "
                "AND ?=1 AND device.relay_generation=? "
                "AND device.lease_expires>? "
                "AND device.acknowledged_sender_key_ids_json<>'[]' "
                "ORDER BY activity.updated_at DESC, activity.activity_id",
                (reference, current_time, 1 if self.relay_config_enabled() else 0,
                 self.relay_config_generation(), current_time),
            ).fetchall()
        return [dict(row) for row in rows]

    def active_relay_live_activity(
        self,
        activity_id: str,
        *,
        expected_session_ref: str = "",
        expected_device_id: str = "",
        expected_revision: int = 0,
        expected_lease_expires: int = 0,
        now: int | None = None,
    ) -> dict[str, Any] | None:
        activity = _protocol_identifier(activity_id, "activity_id")
        current_time = int(time.time()) if now is None else _positive_integer(now, "now")
        with self._connect() as connection:
            row = connection.execute(
                "SELECT activity.* FROM relay_live_activities AS activity "
                "JOIN devices AS device ON device.device_id=activity.device_id "
                "WHERE activity.activity_id=? AND activity.ended_at IS NULL "
                "AND activity.revoked_at IS NULL AND activity.lease_expires>? "
                "AND device.provider='relay' AND device.revoked_at IS NULL "
                "AND ?=1 AND device.relay_generation=? "
                "AND device.lease_expires>? "
                "AND device.acknowledged_sender_key_ids_json<>'[]' "
                "AND (?='' OR activity.session_ref=?) "
                "AND (?='' OR activity.device_id=?) "
                "AND (?=0 OR activity.revision=?) "
                "AND (?=0 OR activity.lease_expires=?)",
                (
                    activity,
                    current_time,
                    1 if self.relay_config_enabled() else 0,
                    self.relay_config_generation(),
                    current_time,
                    expected_session_ref,
                    expected_session_ref,
                    expected_device_id,
                    expected_device_id,
                    expected_revision,
                    expected_revision,
                    expected_lease_expires,
                    expected_lease_expires,
                ),
            ).fetchone()
        return None if row is None else dict(row)

    def allocate_relay_live_activity_timestamp(
        self,
        activity_id: str,
        current_time: int,
        *,
        expected_session_ref: str,
        expected_device_id: str,
        expected_revision: int,
        expected_lease_expires: int,
    ) -> int:
        activity = _protocol_identifier(activity_id, "activity_id")
        current = _positive_integer(current_time, "current_time")
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                "SELECT activity.source_timestamp, activity.last_push_timestamp "
                "FROM relay_live_activities AS activity "
                "JOIN devices AS device ON device.device_id=activity.device_id "
                "WHERE activity.activity_id=? AND activity.ended_at IS NULL "
                "AND activity.revoked_at IS NULL AND activity.lease_expires>? "
                "AND device.provider='relay' AND device.revoked_at IS NULL "
                "AND ?=1 AND device.relay_generation=? "
                "AND device.lease_expires>? "
                "AND device.acknowledged_sender_key_ids_json<>'[]' "
                "AND activity.session_ref=? AND activity.device_id=? "
                "AND activity.revision=? AND activity.lease_expires=?",
                (
                    activity,
                    current,
                    1 if self.relay_config_enabled() else 0,
                    self.relay_config_generation(),
                    current,
                    expected_session_ref,
                    expected_device_id,
                    _positive_revision(expected_revision),
                    _positive_integer(expected_lease_expires, "expected_lease_expires"),
                ),
            ).fetchone()
            if row is None:
                raise ValueError("Unknown, expired, or ended relay Live Activity")
            timestamp = max(
                current,
                int(row["source_timestamp"]) + 1,
                int(row["last_push_timestamp"]) + 1,
            )
            connection.execute(
                "UPDATE relay_live_activities SET last_push_timestamp=?, updated_at=? "
                "WHERE activity_id=? AND ended_at IS NULL AND revoked_at IS NULL "
                "AND session_ref=? AND device_id=? AND revision=? AND lease_expires=?",
                (
                    timestamp,
                    int(time.time()),
                    activity,
                    expected_session_ref,
                    expected_device_id,
                    expected_revision,
                    expected_lease_expires,
                ),
            )
        return timestamp

    def end_relay_live_activity(
        self,
        activity_id: str,
        *,
        expected_session_ref: str = "",
        expected_device_id: str = "",
        expected_revision: int = 0,
        expected_delivery_id: str = "",
        expected_idempotency_key: str = "",
    ) -> bool:
        activity = _protocol_identifier(activity_id, "activity_id")
        now = int(time.time())
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            if expected_delivery_id or expected_idempotency_key:
                pending = connection.execute(
                    "SELECT 1 FROM pending_relay_live_activity_updates "
                    "WHERE activity_id=? "
                    "AND (?='' OR delivery_id=?) "
                    "AND (?='' OR idempotency_key=?) "
                    "AND (?='' OR device_id=?) "
                    "AND (?='' OR session_ref=?) "
                    "AND (?=0 OR revision=?) "
                    "LIMIT 1",
                    (
                        activity,
                        expected_delivery_id,
                        expected_delivery_id,
                        expected_idempotency_key,
                        expected_idempotency_key,
                        expected_device_id,
                        expected_device_id,
                        expected_session_ref,
                        expected_session_ref,
                        expected_revision,
                        expected_revision,
                    ),
                ).fetchone()
                if pending is None:
                    return False
            cursor = connection.execute(
                "UPDATE relay_live_activities SET ended_at=?, updated_at=? "
                "WHERE activity_id=? AND ended_at IS NULL "
                "AND (?='' OR session_ref=?) AND (?='' OR device_id=?) "
                "AND (?=0 OR revision=?)",
                (
                    now,
                    now,
                    activity,
                    expected_session_ref,
                    expected_session_ref,
                    expected_device_id,
                    expected_device_id,
                    expected_revision,
                    expected_revision,
                ),
            )
            if cursor.rowcount:
                connection.execute(
                    "DELETE FROM pending_relay_live_activity_updates WHERE activity_id=? "
                    "AND (?='' OR device_id=?) AND (?='' OR session_ref=?) "
                    "AND (?=0 OR revision=?) "
                    "AND (?='' OR delivery_id=?) "
                    "AND (?='' OR idempotency_key=?)",
                    (
                        activity,
                        expected_device_id,
                        expected_device_id,
                        expected_session_ref,
                        expected_session_ref,
                        expected_revision,
                        expected_revision,
                        expected_delivery_id,
                        expected_delivery_id,
                        expected_idempotency_key,
                        expected_idempotency_key,
                    ),
                )
            return cursor.rowcount == 1

    def defer_relay_live_activity_update(
        self,
        *,
        activity_id: str,
        status: str,
        detail: str,
        tool_name: str,
        active_session_count: int,
        delay_seconds: int,
        failure: str,
        timestamp: int = 0,
        delivery_id: str = "",
        idempotency_key: str = "",
        request_body: Mapping[str, Any] | None = None,
        expected_device_id: str = "",
        expected_session_ref: str = "",
        expected_revision: int = 0,
        expected_lease_expires: int = 0,
        expected_relay_generation: int | None = None,
        expected_delivery_id: str = "",
        expected_idempotency_key: str = "",
    ) -> None:
        now = int(time.time())
        normalized_body = "" if request_body is None else _json(request_body)
        expected_device = (
            "" if not expected_device_id else _identifier(expected_device_id, "expected_device_id")
        )
        expected_session = (
            "" if not expected_session_ref else _required_text(expected_session_ref, "expected_session_ref", 100)
        )
        expected_owner_revision = 0 if not expected_revision else _positive_revision(expected_revision)
        expected_lease = (
            0
            if not expected_lease_expires
            else _positive_integer(expected_lease_expires, "expected_lease_expires")
        )
        expected_generation = (
            None if expected_relay_generation is None else max(0, int(expected_relay_generation))
        )
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            owner = connection.execute(
                "SELECT device_id, session_ref, revision, lease_expires "
                "FROM relay_live_activities WHERE activity_id=?",
                (_identifier(activity_id, "activity_id"),),
            ).fetchone()
            if owner is None:
                raise ValueError("Unknown relay Live Activity owner")
            device = str(owner["device_id"])
            session = str(owner["session_ref"])
            owner_revision = int(owner["revision"])
            lease_expires = int(owner["lease_expires"])
            device_row = connection.execute(
                "SELECT provider, revoked_at, relay_generation FROM devices WHERE device_id=?",
                (device,),
            ).fetchone()
            if (
                device_row is None
                or device_row["provider"] != "relay"
                or device_row["revoked_at"] is not None
            ):
                raise ValueError("Relay Live Activity device is not active")
            generation = int(device_row["relay_generation"])
            if (
                (expected_device and expected_device != device)
                or (expected_session and expected_session != session)
                or (expected_owner_revision and expected_owner_revision != owner_revision)
                or (expected_lease and expected_lease != lease_expires)
                or (expected_generation is not None and expected_generation != generation)
            ):
                raise ValueError("Relay Live Activity pending update owner changed")
            normalized_status = _required_text(status, "status", 40)
            existing = connection.execute(
                "SELECT status, terminal, attempts, delivery_id, idempotency_key "
                "FROM pending_relay_live_activity_updates "
                "WHERE activity_id=?",
                (_identifier(activity_id, "activity_id"),),
            ).fetchone()
            if expected_delivery_id or expected_idempotency_key:
                if existing is None or (
                    expected_delivery_id
                    and str(existing["delivery_id"] or "") != _text(expected_delivery_id, 180)
                ) or (
                    expected_idempotency_key
                    and str(existing["idempotency_key"] or "")
                    != _text(expected_idempotency_key, 180)
                ):
                    raise ValueError("Relay Live Activity pending update request changed")
            if existing is not None:
                previous_status = str(existing["status"])
                previous_terminal = bool(int(existing["terminal"] or 0)) or previous_status in {
                    "completed", "failed"
                }
                routine = {"thinking", "running"}
                if previous_terminal:
                    # A settled terminal is authoritative.  An exhausted
                    # routine row is recoverable, however, so waiting or a
                    # terminal update can replace it and reset its retry cap.
                    if previous_status in {"completed", "failed"}:
                        if not (
                            previous_status == normalized_status
                            and not bool(int(existing["terminal"] or 0))
                        ):
                            return
                    elif normalized_status not in {"waiting", "completed", "failed"}:
                        return
                    else:
                        connection.execute(
                            "UPDATE pending_relay_live_activity_updates SET attempts=0, terminal=0 "
                            "WHERE activity_id=?",
                            (_identifier(activity_id, "activity_id"),),
                        )
                elif previous_status == "waiting" and normalized_status in routine:
                    # Waiting is more actionable than routine progress and
                    # must not be hidden by a later routine coalescing write.
                    return
            connection.execute(
                """
                INSERT INTO pending_relay_live_activity_updates (
                    activity_id, status, detail, tool_name, active_session_count,
                    attempts, next_attempt_at, last_error, updated_at,
                    timestamp, delivery_id, idempotency_key, request_body_json,
                    device_id, session_ref, revision, lease_expires, relay_generation
                ) VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(activity_id) DO UPDATE SET
                    status=excluded.status,
                    detail=excluded.detail,
                    tool_name=excluded.tool_name,
                    active_session_count=excluded.active_session_count,
                    attempts=pending_relay_live_activity_updates.attempts + 1,
                    next_attempt_at=excluded.next_attempt_at,
                    last_error=excluded.last_error,
                    terminal=CASE WHEN pending_relay_live_activity_updates.attempts + 1 >= 5 THEN 1 ELSE 0 END,
                    updated_at=excluded.updated_at,
                    timestamp=CASE
                        WHEN pending_relay_live_activity_updates.device_id != excluded.device_id
                          OR pending_relay_live_activity_updates.session_ref != excluded.session_ref
                          OR pending_relay_live_activity_updates.revision != excluded.revision
                          OR pending_relay_live_activity_updates.lease_expires != excluded.lease_expires
                          OR pending_relay_live_activity_updates.relay_generation != excluded.relay_generation
                        THEN excluded.timestamp
                        WHEN excluded.timestamp=0 THEN pending_relay_live_activity_updates.timestamp
                        ELSE excluded.timestamp
                    END,
                    delivery_id=CASE
                        WHEN pending_relay_live_activity_updates.device_id != excluded.device_id
                          OR pending_relay_live_activity_updates.session_ref != excluded.session_ref
                          OR pending_relay_live_activity_updates.revision != excluded.revision
                          OR pending_relay_live_activity_updates.lease_expires != excluded.lease_expires
                          OR pending_relay_live_activity_updates.relay_generation != excluded.relay_generation
                        THEN excluded.delivery_id
                        WHEN excluded.delivery_id='' THEN pending_relay_live_activity_updates.delivery_id
                        ELSE excluded.delivery_id
                    END,
                    idempotency_key=CASE
                        WHEN pending_relay_live_activity_updates.device_id != excluded.device_id
                          OR pending_relay_live_activity_updates.session_ref != excluded.session_ref
                          OR pending_relay_live_activity_updates.revision != excluded.revision
                          OR pending_relay_live_activity_updates.lease_expires != excluded.lease_expires
                          OR pending_relay_live_activity_updates.relay_generation != excluded.relay_generation
                        THEN excluded.idempotency_key
                        WHEN excluded.idempotency_key='' THEN pending_relay_live_activity_updates.idempotency_key
                        ELSE excluded.idempotency_key
                    END,
                    request_body_json=CASE
                        WHEN pending_relay_live_activity_updates.device_id != excluded.device_id
                          OR pending_relay_live_activity_updates.session_ref != excluded.session_ref
                          OR pending_relay_live_activity_updates.revision != excluded.revision
                          OR pending_relay_live_activity_updates.lease_expires != excluded.lease_expires
                          OR pending_relay_live_activity_updates.relay_generation != excluded.relay_generation
                        THEN excluded.request_body_json
                        WHEN excluded.request_body_json='' THEN pending_relay_live_activity_updates.request_body_json
                        ELSE excluded.request_body_json
                    END,
                    device_id=excluded.device_id,
                    session_ref=excluded.session_ref,
                    revision=excluded.revision,
                    lease_expires=excluded.lease_expires,
                    relay_generation=excluded.relay_generation
                """,
                (
                    _identifier(activity_id, "activity_id"),
                    normalized_status,
                    _text(detail, 180),
                    _text(tool_name, 80),
                    max(0, int(active_session_count)),
                    now + max(0, int(delay_seconds)),
                    _text(failure, 500),
                    now,
                    max(0, int(timestamp)),
                    _text(delivery_id, 180),
                    _text(idempotency_key, 180),
                    normalized_body,
                    device,
                    session,
                    owner_revision,
                    lease_expires,
                    generation,
                ),
            )

    def due_relay_live_activity_updates(self, *, limit: int = 100) -> list[dict[str, Any]]:
        bounded = min(1000, max(1, int(limit)))
        with self._connect() as connection:
            rows = connection.execute(
                """
                SELECT pending.*, activity.device_id, activity.session_ref,
                       activity.revision, activity.lease_expires
                FROM pending_relay_live_activity_updates AS pending
                JOIN relay_live_activities AS activity USING (activity_id)
                WHERE pending.terminal=0 AND pending.next_attempt_at <= ? AND activity.ended_at IS NULL
                  AND activity.revoked_at IS NULL
                ORDER BY pending.next_attempt_at, pending.updated_at
                LIMIT ?
                """,
                (int(time.time()), bounded),
            ).fetchall()
        return [dict(row) for row in rows]

    def pending_relay_live_activity_update(self, activity_id: str) -> dict[str, Any] | None:
        with self._connect() as connection:
            row = connection.execute(
                "SELECT * FROM pending_relay_live_activity_updates WHERE activity_id=?",
                (_identifier(activity_id, "activity_id"),),
            ).fetchone()
        return dict(row) if row is not None else None

    def pending_relay_live_activity_updates(self, *, limit: int = 100) -> list[dict[str, Any]]:
        bounded = min(1000, max(1, int(limit)))
        with self._connect() as connection:
            rows = connection.execute(
                "SELECT * FROM pending_relay_live_activity_updates WHERE terminal=0 "
                "ORDER BY updated_at LIMIT ?",
                (bounded,),
            ).fetchall()
        return [dict(row) for row in rows]

    def clear_pending_relay_live_activity_update(
        self,
        activity_id: str,
        *,
        expected_device_id: str = "",
        expected_session_ref: str = "",
        expected_revision: int = 0,
        expected_lease_expires: int = 0,
        expected_relay_generation: int | None = None,
        expected_delivery_id: str = "",
        expected_idempotency_key: str = "",
    ) -> bool:
        clauses = ["activity_id=?"]
        values: list[Any] = [_identifier(activity_id, "activity_id")]
        if expected_device_id:
            clauses.append("device_id=?")
            values.append(_identifier(expected_device_id, "expected_device_id"))
        if expected_session_ref:
            clauses.append("session_ref=?")
            values.append(_required_text(expected_session_ref, "expected_session_ref", 100))
        if expected_revision:
            clauses.append("revision=?")
            values.append(_positive_revision(expected_revision))
        if expected_lease_expires:
            clauses.append("lease_expires=?")
            values.append(_positive_integer(expected_lease_expires, "expected_lease_expires"))
        if expected_relay_generation is not None:
            clauses.append("relay_generation=?")
            values.append(max(0, int(expected_relay_generation)))
        if expected_delivery_id:
            clauses.append("delivery_id=?")
            values.append(_text(expected_delivery_id, 180))
        if expected_idempotency_key:
            clauses.append("idempotency_key=?")
            values.append(_text(expected_idempotency_key, 180))
        with self._connect() as connection:
            cursor = connection.execute(
                "DELETE FROM pending_relay_live_activity_updates WHERE " + " AND ".join(clauses),
                tuple(values),
            )
            return cursor.rowcount == 1
