"""Direct APNs activity ownership, timestamp allocation and durable recovery."""

from __future__ import annotations

import hashlib
import os
import time
import uuid
from contextlib import contextmanager
from typing import Any
from .store_values import (
    _MAX_RELAY_AUTOMATIC_ATTEMPTS,
    _identifier,
    _lock_file_descriptor,
    _required_text,
    _text,
    _unlock_file_descriptor,
)


class LiveActivityStore:
    def has_pending_live_activity_updates(self) -> bool:
        with self._connect() as connection:
            return connection.execute(
                "SELECT 1 FROM pending_live_activity_updates WHERE terminal=0 LIMIT 1"
            ).fetchone() is not None

    def upsert_live_activity(
        self,
        *,
        session_id: str,
        live_session_id: str,
        profile: str,
        activity_id: str,
        push_token: str,
        token_environment: str,
    ) -> None:
        environment = str(token_environment or "production").strip().lower()
        if environment not in {"production", "sandbox"}:
            raise ValueError("Live Activity environment must be production or sandbox")
        now = int(time.time())
        with self._connect() as connection:
            connection.execute(
                """
                INSERT INTO live_activities (
                    activity_id, session_id, live_session_id, profile, push_token,
                    token_environment, created_at, updated_at, ended_at,
                    owner_generation
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, 1)
                ON CONFLICT(activity_id) DO UPDATE SET
                    session_id=excluded.session_id,
                    live_session_id=excluded.live_session_id,
                    profile=excluded.profile,
                    push_token=excluded.push_token,
                    token_environment=excluded.token_environment,
                    updated_at=excluded.updated_at,
                    owner_generation=live_activities.owner_generation + 1,
                    ended_at=NULL
                """,
                (
                    _identifier(activity_id, "activity_id"),
                    _identifier(session_id, "session_id"),
                    _identifier(live_session_id or session_id, "live_session_id"),
                    _required_text(profile or "default", "profile", 80),
                    _required_text(push_token, "push_token", 512),
                    environment,
                    now,
                    now,
                ),
            )
            connection.execute(
                "DELETE FROM pending_live_activity_updates WHERE activity_id=?",
                (_identifier(activity_id, "activity_id"),),
            )

    def active_live_activities(self, session_id: str, profile: str = "") -> list[dict[str, Any]]:
        identifier = _identifier(session_id, "session_id")
        with self._connect() as connection:
            rows = connection.execute(
                "SELECT * FROM live_activities WHERE ended_at IS NULL "
                "AND (session_id=? OR live_session_id=?) "
                "AND (?='' OR profile=?) ORDER BY updated_at DESC",
                (identifier, identifier, str(profile or ""), str(profile or "")),
            ).fetchall()
        return [dict(row) for row in rows]

    def active_live_activity(
        self,
        activity_id: str,
        *,
        expected_session_id: str = "",
        expected_live_session_id: str = "",
        expected_profile: str = "",
        expected_push_token: str = "",
    ) -> dict[str, Any] | None:
        identifier = _identifier(activity_id, "activity_id")
        with self._connect() as connection:
            row = connection.execute(
                "SELECT * FROM live_activities WHERE activity_id=? AND ended_at IS NULL "
                "AND (?='' OR session_id=?) AND (?='' OR live_session_id=?) "
                "AND (?='' OR profile=?) AND (?='' OR push_token=?)",
                (
                    identifier,
                    expected_session_id,
                    expected_session_id,
                    expected_live_session_id,
                    expected_live_session_id,
                    expected_profile,
                    expected_profile,
                    expected_push_token,
                    expected_push_token,
                ),
            ).fetchone()
        return None if row is None else dict(row)

    @contextmanager
    def live_activity_send_lock(self, activity_id: str):
        identifier = _identifier(activity_id, "activity_id")
        lock_directory = self.path.parent / f".{self.path.name}.live-activity-locks"
        lock_directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        lock_name = hashlib.sha256(identifier.encode("utf-8")).hexdigest()
        descriptor = os.open(lock_directory / lock_name, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            _lock_file_descriptor(descriptor)
            yield
        finally:
            _unlock_file_descriptor(descriptor)
            os.close(descriptor)

    def allocate_live_activity_timestamp(
        self,
        activity_id: str,
        current_time: int,
        *,
        expected_session_id: str = "",
        expected_live_session_id: str = "",
        expected_profile: str = "",
        expected_push_token: str = "",
        expected_owner_generation: int = 0,
    ) -> int:
        identifier = _identifier(activity_id, "activity_id")
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                "SELECT last_push_timestamp FROM live_activities "
                "WHERE activity_id=? AND ended_at IS NULL "
                "AND (?='' OR session_id=?) AND (?='' OR live_session_id=?) "
                "AND (?='' OR profile=?) AND (?='' OR push_token=?) "
                "AND (?=0 OR owner_generation=?)",
                (
                    identifier,
                    expected_session_id,
                    expected_session_id,
                    expected_live_session_id,
                    expected_live_session_id,
                    expected_profile,
                    expected_profile,
                    expected_push_token,
                    expected_push_token,
                    max(0, int(expected_owner_generation)),
                    max(0, int(expected_owner_generation)),
                ),
            ).fetchone()
            if row is None:
                raise ValueError("Unknown or ended Live Activity")
            timestamp = max(int(current_time), int(row["last_push_timestamp"]) + 1)
            connection.execute(
                "UPDATE live_activities SET last_push_timestamp=?, updated_at=? "
                "WHERE activity_id=? AND ended_at IS NULL "
                "AND (?='' OR session_id=?) AND (?='' OR live_session_id=?) "
                "AND (?='' OR profile=?) AND (?='' OR push_token=?) "
                "AND (?=0 OR owner_generation=?)",
                (
                    timestamp,
                    int(time.time()),
                    identifier,
                    expected_session_id,
                    expected_session_id,
                    expected_live_session_id,
                    expected_live_session_id,
                    expected_profile,
                    expected_profile,
                    expected_push_token,
                    expected_push_token,
                    max(0, int(expected_owner_generation)),
                    max(0, int(expected_owner_generation)),
                ),
            )
            return timestamp

    def end_live_activity(
        self,
        activity_id: str,
        *,
        expected_session_id: str = "",
        expected_live_session_id: str = "",
        expected_profile: str = "",
        expected_push_token: str = "",
        expected_owner_generation: int = 0,
        expected_request_id: str = "",
    ) -> bool:
        identifier = _identifier(activity_id, "activity_id")
        owner_generation = max(0, int(expected_owner_generation))
        request_id = str(expected_request_id or "")
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            if request_id:
                pending = connection.execute(
                    "SELECT 1 FROM pending_live_activity_updates "
                    "WHERE activity_id=? AND request_id=? "
                    "AND (?=0 OR owner_generation=?) LIMIT 1",
                    (identifier, _required_text(request_id, "expected_request_id", 512),
                     owner_generation, owner_generation),
                ).fetchone()
                if pending is None:
                    return False
            ended = connection.execute(
                "UPDATE live_activities SET ended_at=?, updated_at=? WHERE activity_id=? "
                "AND (?='' OR session_id=?) AND (?='' OR live_session_id=?) "
                "AND (?='' OR profile=?) AND (?='' OR push_token=?) "
                "AND (?=0 OR owner_generation=?)",
                (
                    int(time.time()),
                    int(time.time()),
                    identifier,
                    expected_session_id,
                    expected_session_id,
                    expected_live_session_id,
                    expected_live_session_id,
                    expected_profile,
                    expected_profile,
                    expected_push_token,
                    expected_push_token,
                    owner_generation,
                    owner_generation,
                ),
            )
            if ended.rowcount:
                connection.execute(
                    "DELETE FROM pending_live_activity_updates WHERE activity_id=? "
                    "AND (?='' OR owner_session_id=?) "
                    "AND (?='' OR owner_live_session_id=?) "
                    "AND (?='' OR owner_profile=?) "
                    "AND (?='' OR owner_push_token=?) "
                    "AND (?=0 OR owner_generation=?) "
                    "AND (?='' OR request_id=?)",
                    (
                        identifier,
                        expected_session_id, expected_session_id,
                        expected_live_session_id, expected_live_session_id,
                        expected_profile, expected_profile,
                        expected_push_token, expected_push_token,
                        owner_generation, owner_generation,
                        request_id, request_id,
                    ),
                )
            return ended.rowcount == 1

    def defer_live_activity_update(
        self,
        *,
        activity_id: str,
        status: str,
        detail: str,
        tool_name: str,
        active_session_count: int,
        delay_seconds: int,
        failure: str,
        expected_session_id: str = "",
        expected_live_session_id: str = "",
        expected_profile: str = "",
        expected_push_token: str = "",
        expected_owner_generation: int = 0,
        expected_request_id: str = "",
    ) -> bool:
        now = int(time.time())
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            owner = connection.execute(
                "SELECT session_id, live_session_id, profile, push_token, owner_generation "
                "FROM live_activities WHERE activity_id=? AND ended_at IS NULL",
                (_identifier(activity_id, "activity_id"),),
            ).fetchone()
            if owner is None:
                raise ValueError("Unknown or ended Live Activity")
            owner_values = {
                "session_id": str(owner["session_id"]),
                "live_session_id": str(owner["live_session_id"]),
                "profile": str(owner["profile"]),
                "push_token": str(owner["push_token"]),
                "owner_generation": int(owner["owner_generation"] or 0),
            }
            expected_owner = max(0, int(expected_owner_generation))
            if (
                (expected_session_id and str(expected_session_id) != owner_values["session_id"])
                or (expected_live_session_id and str(expected_live_session_id) != owner_values["live_session_id"])
                or (expected_profile and str(expected_profile) != owner_values["profile"])
                or (expected_push_token and str(expected_push_token) != owner_values["push_token"])
                or (expected_owner and expected_owner != owner_values["owner_generation"])
            ):
                return False
            normalized_status = _required_text(status, "status", 40)
            existing = connection.execute(
                "SELECT status, terminal, attempts, owner_session_id, owner_live_session_id, "
                "owner_profile, owner_push_token, owner_generation, request_id "
                "FROM pending_live_activity_updates "
                "WHERE activity_id=?",
                (_identifier(activity_id, "activity_id"),),
            ).fetchone()
            if expected_request_id and (
                existing is None
                or str(existing["request_id"] or "") != str(expected_request_id)
                or int(existing["owner_generation"] or 0) != owner_values["owner_generation"]
            ):
                return False
            reset_attempts = False
            if existing is not None:
                previous_status = str(existing["status"])
                previous_terminal = bool(int(existing["terminal"] or 0)) or previous_status in {
                    "completed", "failed"
                }
                routine = {"thinking", "running"}
                if previous_terminal:
                    if previous_status in {"completed", "failed"} or normalized_status not in {
                        "waiting", "completed", "failed"
                    }:
                        # A non-exhausted terminal update may be retried with
                        # the same phase; a different terminal remains
                        # authoritative.  Exhausted terminal rows are never
                        # automatically retried.
                        if not (
                            previous_status == normalized_status
                            and not bool(int(existing["terminal"] or 0))
                        ):
                            return
                    else:
                        reset_attempts = True
                elif previous_status == "waiting" and normalized_status in routine:
                    return
                elif previous_status in routine and normalized_status in {
                    "waiting", "completed", "failed"
                }:
                    reset_attempts = True
                owner_changed = any(
                    str(existing[key] or "") != owner_values[value]
                    for key, value in (
                        ("owner_session_id", "session_id"),
                        ("owner_live_session_id", "live_session_id"),
                        ("owner_profile", "profile"),
                        ("owner_push_token", "push_token"),
                    )
                )
                reset_attempts = reset_attempts or owner_changed
            else:
                reset_attempts = True
            attempts = 1 if reset_attempts else int(existing["attempts"]) + 1
            terminal = int(attempts >= _MAX_RELAY_AUTOMATIC_ATTEMPTS)
            request_id = str(uuid.uuid4())
            connection.execute(
                """
                INSERT INTO pending_live_activity_updates (
                    activity_id, status, detail, tool_name, active_session_count,
                    attempts, next_attempt_at, last_error, updated_at, terminal,
                    owner_session_id, owner_live_session_id, owner_profile,
                    owner_push_token, owner_generation, request_id
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(activity_id) DO UPDATE SET
                    status=excluded.status,
                    detail=excluded.detail,
                    tool_name=excluded.tool_name,
                    active_session_count=excluded.active_session_count,
                    attempts=excluded.attempts,
                    next_attempt_at=excluded.next_attempt_at,
                    last_error=excluded.last_error,
                    updated_at=excluded.updated_at,
                    terminal=excluded.terminal,
                    owner_session_id=excluded.owner_session_id,
                    owner_live_session_id=excluded.owner_live_session_id,
                    owner_profile=excluded.owner_profile,
                    owner_push_token=excluded.owner_push_token,
                    owner_generation=excluded.owner_generation,
                    request_id=excluded.request_id
                """,
                (
                    _identifier(activity_id, "activity_id"),
                    normalized_status,
                    _text(detail, 180),
                    _text(tool_name, 80),
                    max(0, int(active_session_count)),
                    attempts,
                    now + max(0, int(delay_seconds)),
                    _text(failure, 500),
                    now,
                    terminal,
                    owner_values["session_id"],
                    owner_values["live_session_id"],
                    owner_values["profile"],
                    owner_values["push_token"],
                    owner_values["owner_generation"],
                    request_id,
                ),
            )
            return True

    def due_live_activity_updates(self, *, limit: int = 100) -> list[dict[str, Any]]:
        bounded = min(1000, max(1, int(limit)))
        with self._connect() as connection:
            rows = connection.execute(
                """
                SELECT pending.*, activity.push_token, activity.token_environment
                FROM pending_live_activity_updates AS pending
                JOIN live_activities AS activity USING (activity_id)
                WHERE pending.terminal=0 AND pending.next_attempt_at <= ? AND activity.ended_at IS NULL
                ORDER BY pending.next_attempt_at, pending.updated_at
                LIMIT ?
                """,
                (int(time.time()), bounded),
            ).fetchall()
        return [dict(row) for row in rows]

    def clear_pending_live_activity_update(
        self,
        activity_id: str,
        *,
        expected_session_id: str = "",
        expected_live_session_id: str = "",
        expected_profile: str = "",
        expected_push_token: str = "",
        expected_owner_generation: int = 0,
        expected_request_id: str = "",
    ) -> bool:
        clauses = ["activity_id=?"]
        values: list[Any] = [_identifier(activity_id, "activity_id")]
        for column, value, label in (
            ("owner_session_id", expected_session_id, "expected_session_id"),
            ("owner_live_session_id", expected_live_session_id, "expected_live_session_id"),
            ("owner_profile", expected_profile, "expected_profile"),
            ("owner_push_token", expected_push_token, "expected_push_token"),
            ("owner_generation", expected_owner_generation, "expected_owner_generation"),
            ("request_id", expected_request_id, "expected_request_id"),
        ):
            if value:
                clauses.append(f"{column}=?")
                values.append(_required_text(value, label, 512))
        with self._connect() as connection:
            cursor = connection.execute(
                "DELETE FROM pending_live_activity_updates WHERE " + " AND ".join(clauses),
                tuple(values),
            )
            return cursor.rowcount == 1

    def pending_live_activity_update(self, activity_id: str) -> dict[str, Any] | None:
        with self._connect() as connection:
            row = connection.execute(
                "SELECT * FROM pending_live_activity_updates WHERE activity_id=?",
                (_identifier(activity_id, "activity_id"),),
            ).fetchone()
        return dict(row) if row is not None else None

    def pending_live_activity_updates(self) -> list[dict[str, Any]]:
        with self._connect() as connection:
            rows = connection.execute(
                "SELECT * FROM pending_live_activity_updates ORDER BY updated_at"
            ).fetchall()
        return [dict(row) for row in rows]
