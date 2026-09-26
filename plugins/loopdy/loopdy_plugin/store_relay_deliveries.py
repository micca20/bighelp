"""Legacy relay delivery journal compatibility and immutable claim coordinates."""

from __future__ import annotations

import time
import uuid
from typing import Any, Mapping
from .store_values import (
    _CLAIM_LEASE_SECONDS,
    _MAX_RELAY_AUTOMATIC_ATTEMPTS,
    _delivery_status,
    _event_row,
    _identifier,
    _json,
    _required_text,
    _text,
)


class RelayDeliveryStore:
    def admit_relay_delivery(
        self,
        *,
        event_id: str,
        device_id: str,
        delivery_id: str,
        status: str = "queued",
        failure: str = "",
        target_revision: int,
        target_generation: int,
        target_key_id: str = "",
        target_sender_key_id: str = "",
        relay_request_body: Mapping[str, Any] | None = None,
    ) -> dict[str, Any]:
        """Insert a relay delivery once and return its authoritative row.

        Admission is deliberately separate from the general delivery ledger
        upsert: concurrent processes may have already prepared different
        ciphertext, but only the first transaction may establish the frozen
        request and coordinates.  A later caller must claim and use this row
        rather than overwrite it or reset another caller's lease.
        """
        normalized_body = "" if relay_request_body is None else _json(relay_request_body)
        normalized_event = _identifier(event_id, "event_id")
        normalized_device = _identifier(device_id, "device_id")
        normalized_status = _delivery_status(status)
        now = int(time.time())
        normalized_revision = max(0, int(target_revision))
        normalized_generation = max(0, int(target_generation))
        normalized_delivery = _text(delivery_id, 180)
        normalized_key = _text(target_key_id, 64)
        normalized_sender = _text(target_sender_key_id, 64)
        normalized_failure = _text(failure, 500)
        with self._connect() as connection:
            connection.execute(
                """
                INSERT INTO event_deliveries (
                    event_id, device_id, provider, status, attempts, delivery_id,
                    failure, created_at, updated_at, target_revision, target_key_id,
                    target_generation, target_sender_key_id, relay_request_body_json
                ) VALUES (?, ?, 'relay', ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(event_id, device_id) DO NOTHING
                """,
                (
                    normalized_event,
                    normalized_device,
                    normalized_status,
                    normalized_delivery,
                    normalized_failure,
                    now,
                    now,
                    normalized_revision,
                    normalized_key,
                    normalized_generation,
                    normalized_sender,
                    normalized_body,
                ),
            )
            row = connection.execute(
                "SELECT * FROM event_deliveries WHERE event_id=? AND device_id=?",
                (normalized_event, normalized_device),
            ).fetchone()
            if row is not None and str(row["status"]) == "queued":
                ownership_changed = (
                    int(row["target_revision"] or 0) != normalized_revision
                    or int(row["target_generation"] or 0) != normalized_generation
                )
                claim_free = not str(row["claim_token"] or "") or int(row["claim_expires"] or 0) <= now
                if ownership_changed and claim_free:
                    connection.execute(
                        "UPDATE event_deliveries SET delivery_id=?, failure=?, updated_at=?, "
                        "target_revision=?, target_key_id=?, target_generation=?, "
                        "target_sender_key_id=?, relay_request_body_json=?, claim_token='', claim_expires=0 "
                        "WHERE event_id=? AND device_id=? AND status='queued' "
                        "AND (claim_token='' OR claim_expires<=?)",
                        (
                            normalized_delivery,
                            normalized_failure,
                            now,
                            normalized_revision,
                            normalized_key,
                            normalized_generation,
                            normalized_sender,
                            normalized_body,
                            normalized_event,
                            normalized_device,
                            now,
                        ),
                    )
                    row = connection.execute(
                        "SELECT * FROM event_deliveries WHERE event_id=? AND device_id=?",
                        (normalized_event, normalized_device),
                    ).fetchone()
        if row is None:
            raise ValueError("Relay delivery admission failed")
        return dict(row)

    def claim_relay_delivery(
        self,
        *,
        event_id: str,
        device_id: str,
        lease_seconds: int = _CLAIM_LEASE_SECONDS,
        ignore_due: bool = False,
    ) -> dict[str, Any] | None:
        now = int(time.time())
        token = str(uuid.uuid4())
        with self._connect() as connection:
            cursor = connection.execute(
                "UPDATE event_deliveries SET claim_token=?, claim_expires=?, attempts=attempts+1, "
                "updated_at=? WHERE event_id=? AND device_id=? AND provider='relay' AND status='queued' "
                "AND (?=1 OR next_attempt_at<=?) AND (claim_token='' OR claim_expires<=?)",
                (
                    token, now + max(5, int(lease_seconds)), now,
                    _identifier(event_id, "event_id"), _identifier(device_id, "device_id"),
                    1 if ignore_due else 0, now, now,
                ),
            )
            if cursor.rowcount != 1:
                return None
            row = connection.execute(
                "SELECT * FROM event_deliveries WHERE event_id=? AND device_id=?",
                (_identifier(event_id, "event_id"), _identifier(device_id, "device_id")),
            ).fetchone()
        return None if row is None else dict(row)

    def finalize_relay_delivery(
        self,
        *,
        event_id: str,
        device_id: str,
        claim_token: str,
        status: str,
        delivery_id: str = "",
        failure: str = "",
        next_attempt_at: int = 0,
        expected_target_revision: int | None = None,
        expected_target_generation: int | None = None,
    ) -> bool:
        normalized_status = _delivery_status(status)
        if normalized_status not in {"queued", "sent", "failed"}:
            raise ValueError("Invalid relay delivery final status")
        now = int(time.time())
        with self._connect() as connection:
            clauses = [
                "event_id=?", "device_id=?", "provider='relay'", "status='queued'", "claim_token=?"
            ]
            where_values: list[Any] = [
                _identifier(event_id, "event_id"), _identifier(device_id, "device_id"),
                _required_text(claim_token, "claim_token", 180),
            ]
            if expected_target_revision is not None:
                clauses.append("target_revision=?")
                where_values.append(max(0, int(expected_target_revision)))
            if expected_target_generation is not None:
                clauses.append("target_generation=?")
                where_values.append(max(0, int(expected_target_generation)))
            current = connection.execute(
                "SELECT attempts FROM event_deliveries WHERE " + " AND ".join(clauses),
                tuple(where_values),
            ).fetchone()
            if current is None:
                return False
            if normalized_status == "queued" and int(current["attempts"]) >= _MAX_RELAY_AUTOMATIC_ATTEMPTS:
                normalized_status = "failed"
                failure = failure or "relay_retry_exhausted"
            terminal = normalized_status != "queued"
            cursor = connection.execute(
                "UPDATE event_deliveries SET status=?, "
                "delivery_id=CASE WHEN ?='' THEN delivery_id ELSE ? END, failure=?, updated_at=?, "
                "next_attempt_at=?, claim_token='', claim_expires=0, "
                "relay_request_body_json=CASE WHEN ? THEN '' ELSE relay_request_body_json END "
                "WHERE " + " AND ".join(clauses),
                (
                    normalized_status, _text(delivery_id, 180), _text(delivery_id, 180),
                    _text(failure, 500), now,
                    0 if terminal else max(now + 1, int(next_attempt_at)), terminal,
                    *where_values,
                ),
            )
            return cursor.rowcount == 1

    def queued_relay_events(self, *, limit: int = 100) -> list[dict[str, Any]]:
        bounded = min(1000, max(1, int(limit)))
        with self._connect() as connection:
            rows = connection.execute(
                "SELECT events.* FROM events WHERE EXISTS ("
                "SELECT 1 FROM event_deliveries WHERE event_deliveries.event_id=events.event_id "
                "AND provider='relay' AND status='queued' AND next_attempt_at<=? "
                "AND (claim_token='' OR claim_expires<=?)) "
                "ORDER BY events.created_at, events.rowid LIMIT ?",
                (int(time.time()), int(time.time()), bounded),
            ).fetchall()
        return [_event_row(row) for row in rows]
