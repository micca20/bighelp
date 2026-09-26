"""Legacy relay operation journal compatibility and claim fencing."""

from __future__ import annotations

import hashlib
import hmac
import time
import uuid
from typing import Any, Mapping
from .store_values import (
    _CLAIM_LEASE_SECONDS,
    _LEGACY_RELAY_PROVIDER_CONFLICT,
    _MAX_RELAY_AUTOMATIC_ATTEMPTS,
    _UUID,
    _identifier,
    _json,
    _positive_revision,
    _relay_operation_name,
    _required_text,
    _text,
)


class RelayOperationStore:
    def has_pending_relay_operations(self) -> bool:
        with self._connect() as connection:
            return connection.execute(
                "SELECT 1 FROM pending_relay_operations WHERE terminal=0 LIMIT 1"
            ).fetchone() is not None

    def save_pending_relay_operation(
        self,
        *,
        operation: str,
        device_id: str,
        revision: int,
        idempotency_key: str,
        body: Mapping[str, Any],
        relay_generation: int = 0,
    ) -> None:
        normalized_operation = _relay_operation_name(operation)
        normalized_device = _identifier(device_id, "device_id")
        normalized_revision = _positive_revision(revision)
        normalized_key = _required_text(idempotency_key, "idempotency_key", 180)
        if _UUID.fullmatch(normalized_key) is None:
            raise ValueError("idempotency_key must be a lowercase UUID")
        body_json = _json(body)
        request_digest = hashlib.sha256(body_json.encode("utf-8")).hexdigest()
        now = int(time.time())
        with self._connect() as connection:
            # Admission is a compare-and-insert transaction.  Without an
            # immediate write lock, two processes can both observe no row and
            # race into the primary-key insert.
            connection.execute("BEGIN IMMEDIATE")
            existing = connection.execute(
                "SELECT body_json, request_digest, revision, idempotency_key, relay_generation "
                "FROM pending_relay_operations WHERE operation=? AND device_id=?",
                (normalized_operation, normalized_device),
            ).fetchone()
            if existing is not None:
                existing_digest = str(existing["request_digest"] or "")
                if not existing_digest:
                    existing_digest = hashlib.sha256(str(existing["body_json"]).encode("utf-8")).hexdigest()
                if (
                    not hmac.compare_digest(existing_digest, request_digest)
                    or int(existing["revision"]) != normalized_revision
                    or str(existing["idempotency_key"]) != normalized_key
                    or int(existing["relay_generation"]) != max(0, int(relay_generation))
                ):
                    raise ValueError("Relay operation request conflict")
                return
            connection.execute(
                """
                INSERT INTO pending_relay_operations (
                    operation, device_id, revision, idempotency_key, body_json,
                    response_json, relay_generation, request_digest, attempts, updated_at,
                    next_attempt_at, claim_token, claim_expires, terminal, last_error, row_version
                ) VALUES (?, ?, ?, ?, ?, '', ?, ?, 0, ?, ?, '', 0, 0, '', 1)
                """,
                (
                    normalized_operation,
                    normalized_device,
                    normalized_revision,
                    normalized_key,
                    body_json,
                    max(0, int(relay_generation)),
                    request_digest,
                    now,
                    now,
                ),
            )

    def claim_pending_relay_operations(
        self, *, limit: int = 100, lease_seconds: int = _CLAIM_LEASE_SECONDS,
        ignore_due: bool = False,
    ) -> list[dict[str, Any]]:
        bounded = min(100, max(1, int(limit)))
        now = int(time.time())
        lease = max(5, int(lease_seconds))
        claimed: list[dict[str, Any]] = []
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            rows = connection.execute(
                "SELECT * FROM pending_relay_operations WHERE terminal=0 "
                "AND (?=1 OR next_attempt_at<=?) "
                "AND (claim_token='' OR claim_expires<=?) "
                "ORDER BY next_attempt_at, updated_at LIMIT ?",
                (1 if ignore_due else 0, now, now, bounded),
            ).fetchall()
            for row in rows:
                token = str(uuid.uuid4())
                cursor = connection.execute(
                    "UPDATE pending_relay_operations SET claim_token=?, claim_expires=?, "
                    "attempts=attempts+1, updated_at=?, row_version=row_version+1 "
                    "WHERE operation=? AND device_id=? AND row_version=? AND terminal=0 "
                    "AND (?=1 OR next_attempt_at<=?) AND (claim_token='' OR claim_expires<=?)",
                    (token, now + lease, now, row["operation"], row["device_id"], row["row_version"],
                     1 if ignore_due else 0, now, now),
                )
                if cursor.rowcount:
                    claimed_row = dict(row)
                    claimed_row.update(
                        claim_token=token,
                        claim_expires=now + lease,
                        attempts=int(row["attempts"]) + 1,
                        updated_at=now,
                        row_version=int(row["row_version"]) + 1,
                    )
                    claimed.append(claimed_row)
        return claimed

    def claim_pending_relay_operation(
        self,
        operation: str,
        device_id: str,
        *,
        lease_seconds: int = _CLAIM_LEASE_SECONDS,
        ignore_due: bool = False,
    ) -> dict[str, Any] | None:
        """Claim exactly one synchronous operation without leasing siblings."""
        normalized_device = _identifier(device_id, "device_id")
        normalized_operation = _relay_operation_name(operation)
        now = int(time.time())
        lease = max(5, int(lease_seconds))
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                "SELECT * FROM pending_relay_operations WHERE operation IN (?, ?) AND device_id=? "
                "AND terminal=0 AND (?=1 OR next_attempt_at<=?) "
                "AND (claim_token='' OR claim_expires<=?) "
                "ORDER BY CASE operation WHEN 'revoke_device' THEN 0 ELSE 1 END LIMIT 1",
                (normalized_operation, "device_revoke", normalized_device,
                 1 if ignore_due else 0, now, now),
            ).fetchone()
            if row is None:
                return None
            token = str(uuid.uuid4())
            cursor = connection.execute(
                "UPDATE pending_relay_operations SET claim_token=?, claim_expires=?, "
                "attempts=attempts+1, updated_at=?, row_version=row_version+1 "
                "WHERE operation=? AND device_id=? AND row_version=? AND terminal=0 "
                "AND (?=1 OR next_attempt_at<=?) AND (claim_token='' OR claim_expires<=?)",
                (token, now + lease, now, row["operation"], row["device_id"], row["row_version"],
                 1 if ignore_due else 0, now, now),
            )
            if cursor.rowcount != 1:
                return None
            result = dict(row)
            result.update(
                claim_token=token,
                claim_expires=now + lease,
                attempts=int(row["attempts"]) + 1,
                updated_at=now,
                row_version=int(row["row_version"]) + 1,
            )
            return result

    def record_relay_operation_response(
        self,
        *,
        operation: str,
        device_id: str,
        response: Mapping[str, Any],
        claim_token: str = "",
        request_digest: str = "",
        relay_generation: int | None = None,
        keep_claim: bool = False,
    ) -> bool:
        normalized_operation = _relay_operation_name(operation)
        normalized_device = _identifier(device_id, "device_id")
        conditions = ["operation IN (?, ?)", "device_id=?", "terminal=0"]
        values: list[Any] = [normalized_operation, "device_revoke", normalized_device]
        if claim_token:
            conditions.append("claim_token=?")
            values.append(_required_text(claim_token, "claim_token", 180))
        if request_digest:
            conditions.append("request_digest=?")
            values.append(_required_text(request_digest, "request_digest", 64))
        if relay_generation is not None:
            conditions.append("relay_generation=?")
            values.append(max(0, int(relay_generation)))
        with self._connect() as connection:
            claim_update = "" if keep_claim else "claim_token='', claim_expires=0,"
            cursor = connection.execute(
                "UPDATE pending_relay_operations SET response_json=?, updated_at=?, "
                + claim_update + " next_attempt_at=0, row_version=row_version+1 "
                "WHERE " + " AND ".join(conditions),
                (_json(response), int(time.time()), *values),
            )
            return cursor.rowcount == 1

    def defer_relay_operation(
        self,
        *,
        operation: str,
        device_id: str,
        claim_token: str,
        request_digest: str,
        delay_seconds: int,
        failure: str,
        terminal: bool = False,
    ) -> bool:
        conditions = ["operation IN (?, ?)", "device_id=?", "claim_token=?", "request_digest=?", "terminal=0"]
        values: list[Any] = [
            _relay_operation_name(operation),
            "device_revoke",
            _identifier(device_id, "device_id"),
            _required_text(claim_token, "claim_token", 180),
            _required_text(request_digest, "request_digest", 64),
        ]
        now = int(time.time())
        with self._connect() as connection:
            row = connection.execute(
                "SELECT attempts FROM pending_relay_operations WHERE " + " AND ".join(conditions),
                tuple(values),
            ).fetchone()
            if row is None:
                return False
            exhausted = terminal or int(row["attempts"]) >= _MAX_RELAY_AUTOMATIC_ATTEMPTS
            cursor = connection.execute(
                "UPDATE pending_relay_operations SET next_attempt_at=?, last_error=?, terminal=?, "
                "claim_token='', claim_expires=0, updated_at=?, row_version=row_version+1 WHERE "
                + " AND ".join(conditions),
                (0 if exhausted else now + max(1, int(delay_seconds)), _text(failure, 500), int(exhausted), now, *values),
            )
            return cursor.rowcount == 1

    def relay_operation_claim_active(
        self,
        operation: str,
        device_id: str,
        *,
        claim_token: str,
        request_digest: str,
        relay_generation: int,
    ) -> bool:
        with self._connect() as connection:
            row = connection.execute(
                "SELECT 1 FROM pending_relay_operations WHERE operation IN (?, ?) "
                "AND device_id=? AND terminal=0 AND claim_token=? AND request_digest=? "
                "AND relay_generation=? LIMIT 1",
                (
                    _relay_operation_name(operation), "device_revoke",
                    _identifier(device_id, "device_id"),
                    _required_text(claim_token, "claim_token", 180),
                    _required_text(request_digest, "request_digest", 64),
                    max(0, int(relay_generation)),
                ),
            ).fetchone()
        return row is not None

    def quarantine_relay_operation(
        self,
        operation: str,
        device_id: str,
        *,
        error: str,
        claim_token: str = "",
        request_digest: str = "",
        relay_generation: int | None = None,
    ) -> bool:
        clauses = ["operation IN (?, ?)", "device_id=?", "terminal=0"]
        values: list[Any] = [_relay_operation_name(operation), "device_revoke", _identifier(device_id, "device_id")]
        if claim_token:
            clauses.append("claim_token=?")
            values.append(_required_text(claim_token, "claim_token", 180))
        if request_digest:
            clauses.append("request_digest=?")
            values.append(_required_text(request_digest, "request_digest", 64))
        if relay_generation is not None:
            clauses.append("relay_generation=?")
            values.append(max(0, int(relay_generation)))
        with self._connect() as connection:
            cursor = connection.execute(
                "UPDATE pending_relay_operations SET terminal=1, last_error=?, "
                "claim_token='', claim_expires=0, next_attempt_at=0, updated_at=?, row_version=row_version+1 "
                "WHERE " + " AND ".join(clauses),
                (_text(error, 500), int(time.time()), *values),
            )
            return cursor.rowcount == 1

    def reset_relay_operation(
        self, operation: str, device_id: str, *, request_digest: str
    ) -> bool:
        now = int(time.time())
        with self._connect() as connection:
            cursor = connection.execute(
                "UPDATE pending_relay_operations SET terminal=0, last_error='', response_json='', "
                "attempts=0, next_attempt_at=?, claim_token='', claim_expires=0, updated_at=?, "
                "row_version=row_version+1 WHERE operation IN (?, ?) AND device_id=? "
                "AND request_digest=? AND terminal=1 AND (claim_token='' OR claim_expires<=?)",
                (now, now, _relay_operation_name(operation), "device_revoke",
                 _identifier(device_id, "device_id"), _required_text(request_digest, "request_digest", 64), now),
            )
            return cursor.rowcount == 1

    def claim_terminal_provider_conflict_registrations(self, *, limit: int = 10) -> list[dict[str, Any]]:
        bounded = min(10, max(1, int(limit)))
        now = int(time.time())
        claimed: list[dict[str, Any]] = []
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            generation = self._metadata_integer(connection, "relay_config_generation", 0)
            rows = connection.execute(
                "SELECT * FROM pending_relay_operations WHERE operation='register_device' "
                "AND terminal=1 AND response_json<>'' AND last_error=? AND relay_generation=? "
                "AND (claim_token='' OR claim_expires<=?) ORDER BY updated_at LIMIT ?",
                (_LEGACY_RELAY_PROVIDER_CONFLICT, generation, now, bounded),
            ).fetchall()
            for row in rows:
                token = str(uuid.uuid4())
                cursor = connection.execute(
                    "UPDATE pending_relay_operations SET claim_token=?, claim_expires=?, updated_at=?, "
                    "row_version=row_version+1 WHERE operation='register_device' AND device_id=? "
                    "AND row_version=? AND terminal=1 AND response_json<>'' AND last_error=? "
                    "AND relay_generation=? AND (claim_token='' OR claim_expires<=?)",
                    (
                        token, now + _CLAIM_LEASE_SECONDS, now, row["device_id"], row["row_version"],
                        _LEGACY_RELAY_PROVIDER_CONFLICT, generation, now,
                    ),
                )
                if cursor.rowcount == 1:
                    claimed_row = dict(row)
                    claimed_row.update(
                        claim_token=token,
                        claim_expires=now + _CLAIM_LEASE_SECONDS,
                        updated_at=now,
                        row_version=int(row["row_version"]) + 1,
                    )
                    claimed.append(claimed_row)
        return claimed

    def release_terminal_provider_conflict_registration(
        self, *, device_id: str, claim_token: str, request_digest: str, relay_generation: int
    ) -> bool:
        with self._connect() as connection:
            cursor = connection.execute(
                "UPDATE pending_relay_operations SET claim_token='', claim_expires=0, updated_at=?, "
                "row_version=row_version+1 WHERE operation='register_device' AND device_id=? "
                "AND terminal=1 AND response_json<>'' AND last_error=? AND claim_token=? "
                "AND request_digest=? AND relay_generation=?",
                (
                    int(time.time()), _identifier(device_id, "device_id"),
                    _LEGACY_RELAY_PROVIDER_CONFLICT, _required_text(claim_token, "claim_token", 180),
                    _required_text(request_digest, "request_digest", 64), max(0, int(relay_generation)),
                ),
            )
            return cursor.rowcount == 1

    def pending_relay_operation(self, operation: str, device_id: str) -> dict[str, Any] | None:
        with self._connect() as connection:
            row = connection.execute(
                "SELECT * FROM pending_relay_operations WHERE operation IN (?, ?) AND device_id=? "
                "ORDER BY CASE operation WHEN 'revoke_device' THEN 0 ELSE 1 END LIMIT 1",
                (_relay_operation_name(operation), "device_revoke", _identifier(device_id, "device_id")),
            ).fetchone()
        return None if row is None else dict(row)

    def pending_relay_operations(self, *, limit: int = 100) -> list[dict[str, Any]]:
        bounded = min(1000, max(1, int(limit)))
        with self._connect() as connection:
            rows = connection.execute(
                "SELECT * FROM pending_relay_operations WHERE terminal=0 ORDER BY updated_at LIMIT ?",
                (bounded,),
            ).fetchall()
        return [dict(row) for row in rows]

    def clear_pending_relay_operation(
        self,
        operation: str,
        device_id: str,
        *,
        claim_token: str = "",
        request_digest: str = "",
        relay_generation: int | None = None,
    ) -> bool:
        clauses = ["operation IN (?, ?)", "device_id=?"]
        values: list[Any] = [_relay_operation_name(operation), "device_revoke", _identifier(device_id, "device_id")]
        if claim_token:
            clauses.append("claim_token=?")
            values.append(_required_text(claim_token, "claim_token", 180))
        if request_digest:
            clauses.append("request_digest=?")
            values.append(_required_text(request_digest, "request_digest", 64))
        if relay_generation is not None:
            clauses.append("relay_generation=?")
            values.append(max(0, int(relay_generation)))
        with self._connect() as connection:
            cursor = connection.execute(
                "DELETE FROM pending_relay_operations WHERE " + " AND ".join(clauses),
                tuple(values),
            )
            return cursor.rowcount == 1
