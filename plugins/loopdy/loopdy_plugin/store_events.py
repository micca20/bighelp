"""Notification event presentation, dismissal and immutable turn-duration metadata."""

from __future__ import annotations

import sqlite3
import time
from typing import Any, Iterable
from .events import LoopdyEvent
from .store_values import (
    _GATEWAY_LIFECYCLE_PREFIXES,
    _event_row,
    _json,
    _load_json,
    _text,
)


class EventStore:
    def record_turn_duration(
        self, session_id: str, turn_id: str, final_timestamp: float, duration_ms: int
    ) -> None:
        """Immutable completion keyed by the host turn, not message text or arrival time."""
        with self._connect() as connection:
            connection.execute(
                "INSERT OR IGNORE INTO turn_durations "
                "(session_id, turn_id, final_timestamp, duration_ms) VALUES (?, ?, ?, ?)",
                (session_id, turn_id, final_timestamp, duration_ms),
            )

    def delete_turn_durations(self, session_id: str) -> None:
        with self._connect() as connection:
            connection.execute("DELETE FROM turn_durations WHERE session_id = ?", (session_id,))

    def turn_durations(self, session_id: str) -> dict[float, int]:
        with self._connect() as connection:
            rows = connection.execute(
                "SELECT final_timestamp, MIN(duration_ms) AS duration_ms "
                "FROM turn_durations WHERE session_id = ? GROUP BY final_timestamp "
                "HAVING COUNT(*) = 1", (session_id,),
            ).fetchall()
        return {row["final_timestamp"]: row["duration_ms"] for row in rows}

    def record_event(self, event: LoopdyEvent, *, target: str = "all") -> bool:
        with self._connect() as connection:
            cursor = connection.execute(
                """
                INSERT OR IGNORE INTO events (
                    event_id, type, status, target, profile, session_id, job_id, task_id,
                    approval_id, delegation_id, detail_json, push_json, created_at
                ) VALUES (?, ?, 'queued', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    event.event_id,
                    event.type,
                    target,
                    event.profile,
                    event.session_id,
                    event.job_id,
                    event.task_id,
                    event.approval_id,
                    event.delegation_id,
                    _json(dict(event.detail)),
                    _json(event.push_payload),
                    int(time.time()),
                ),
            )
            return cursor.rowcount == 1

    def get_event(self, event_id: str) -> dict[str, Any] | None:
        with self._connect() as connection:
            row = connection.execute(
                "SELECT * FROM events WHERE event_id=?", (str(event_id),)
            ).fetchone()
        return _event_row(row) if row is not None else None

    def mark_event_delivered(self, event_id: str, delivery_id: str = "") -> bool:
        with self._connect() as connection:
            cursor = connection.execute(
                "UPDATE events SET status='sent', delivered_at=?, delivery_id=?, failure=NULL "
                "WHERE event_id=?",
                (int(time.time()), _text(delivery_id, 180), str(event_id)),
            )
            return cursor.rowcount == 1

    def mark_event_prompted(self, event_id: str) -> bool:
        with self._connect() as connection:
            cursor = connection.execute(
                "UPDATE events SET status='prompted', failure=NULL "
                "WHERE event_id=? AND status='queued'",
                (str(event_id),),
            )
            return cursor.rowcount == 1

    def mark_event_pending(self, event_id: str, delivery_id: str) -> bool:
        with self._connect() as connection:
            cursor = connection.execute(
                "UPDATE events SET status='pending', delivery_id=?, failure=NULL "
                "WHERE event_id=?",
                (_text(delivery_id, 180), str(event_id)),
            )
            return cursor.rowcount == 1

    def mark_event_failed(self, event_id: str, failure: str) -> bool:
        with self._connect() as connection:
            cursor = connection.execute(
                "UPDATE events SET status='failed', failure=? WHERE event_id=?",
                (_text(failure, 500), str(event_id)),
            )
            return cursor.rowcount == 1

    def list_events(self, *, limit: int = 100, offset: int = 0) -> list[dict[str, Any]]:
        bounded = min(200, max(1, int(limit)))
        bounded_offset = max(0, int(offset))
        with self._connect() as connection:
            rows = connection.execute(
                "SELECT * FROM events WHERE dismissed_at IS NULL "
                "ORDER BY (pinned_at IS NOT NULL) DESC, pinned_at DESC, "
                "created_at DESC, rowid DESC LIMIT ? OFFSET ?",
                (bounded, bounded_offset),
            ).fetchall()
        return [_event_row(row) for row in rows]

    def set_event_state(
        self,
        event_id: str,
        *,
        is_read: bool,
        is_pinned: bool,
        changed_at: int | None = None,
    ) -> bool:
        changed = int(time.time()) if changed_at is None else int(changed_at)
        with self._connect() as connection:
            cursor = connection.execute(
                "UPDATE events SET "
                "read_at=CASE WHEN ? THEN COALESCE(read_at, ?) ELSE NULL END, "
                "pinned_at=CASE WHEN ? THEN COALESCE(pinned_at, ?) ELSE NULL END "
                "WHERE event_id=? AND dismissed_at IS NULL",
                (bool(is_read), changed, bool(is_pinned), changed, str(event_id)),
            )
            return cursor.rowcount == 1

    def dismiss_event(self, event_id: str, *, dismissed_at: int | None = None) -> bool:
        with self._connect() as connection:
            cursor = connection.execute(
                "UPDATE events SET dismissed_at=COALESCE(dismissed_at, ?) WHERE event_id=?",
                (
                    int(time.time()) if dismissed_at is None else int(dismissed_at),
                    str(event_id),
                ),
            )
            return cursor.rowcount == 1

    def dismiss_events(
        self,
        *,
        event_ids: Iterable[str] = (),
        event_types: Iterable[str] = (),
        created_before: int | None = None,
        dismissed_at: int | None = None,
    ) -> int:
        ids = tuple(dict.fromkeys(_text(value, 220) for value in event_ids if _text(value, 220)))
        types = tuple(dict.fromkeys(_text(value, 80) for value in event_types if _text(value, 80)))
        if bool(ids) == bool(types):
            raise ValueError("Choose event_ids or event_types")
        values: list[Any] = [
            int(time.time()) if dismissed_at is None else int(dismissed_at)
        ]
        if ids:
            selector = "event_id IN ({})".format(",".join("?" for _ in ids))
            values.extend(ids)
        else:
            selector = "type IN ({})".format(",".join("?" for _ in types))
            values.extend(types)
        cutoff = ""
        if created_before is not None:
            cutoff = " AND created_at<=?"
            values.append(int(created_before))
        with self._connect() as connection:
            cursor = connection.execute(
                f"UPDATE events SET dismissed_at=? WHERE dismissed_at IS NULL "
                f"AND {selector}{cutoff}",
                tuple(values),
            )
            return cursor.rowcount

    def dismiss_attention_request(
        self,
        request_id: str,
        *,
        session_id: str = "",
        dismissed_at: int | None = None,
    ) -> int:
        request = _text(request_id, 180)
        session = _text(session_id, 180)
        if not request:
            return 0
        with self._connect() as connection:
            rows = connection.execute(
                "SELECT event_id, detail_json FROM events WHERE type='attention.required' "
                "AND dismissed_at IS NULL AND (?='' OR session_id=?)",
                (session, session),
            ).fetchall()
            event_ids = [
                str(row["event_id"])
                for row in rows
                if _text(_load_json(row["detail_json"], {}).get("request_id"), 180)
                == request
            ]
            return self._dismiss_event_ids(
                connection,
                event_ids,
                dismissed_at=dismissed_at,
            )

    def dismiss_attention_for_session(
        self,
        session_id: str,
        *,
        dismissed_at: int | None = None,
    ) -> int:
        session = _text(session_id, 180)
        if not session:
            return 0
        dismissed = int(time.time()) if dismissed_at is None else int(dismissed_at)
        with self._connect() as connection:
            rows = connection.execute(
                "SELECT event_id, detail_json FROM events "
                "WHERE type='attention.required' AND dismissed_at IS NULL "
                "AND session_id=?",
                (session,),
            ).fetchall()
            event_ids = []
            for row in rows:
                detail = _load_json(row["detail_json"], {})
                expiry = _text(detail.get("expires_at"), 64)
                is_expired_clarify = (
                    _text(detail.get("kind"), 80) == "clarify"
                    and expiry.isdigit()
                    and int(expiry) <= dismissed
                )
                if not is_expired_clarify:
                    event_ids.append(str(row["event_id"]))
            return self._dismiss_event_ids(
                connection,
                event_ids,
                dismissed_at=dismissed,
            )

    def dismiss_expired_attention(
        self,
        created_before: int,
        *,
        dismissed_at: int | None = None,
    ) -> int:
        with self._connect() as connection:
            rows = connection.execute(
                "SELECT event_id, detail_json FROM events "
                "WHERE type='attention.required' AND dismissed_at IS NULL "
                "AND created_at<=?",
                (int(created_before),),
            ).fetchall()
            event_ids = [
                str(row["event_id"])
                for row in rows
                if _text(_load_json(row["detail_json"], {}).get("kind"), 80)
                != "clarify"
            ]
            return self._dismiss_event_ids(
                connection,
                event_ids,
                dismissed_at=dismissed_at,
            )

    def dismiss_inactive_approval_events(
        self,
        *,
        now: int | None = None,
        dismissed_at: int | None = None,
    ) -> int:
        current = int(time.time()) if now is None else int(now)
        dismissed = current if dismissed_at is None else int(dismissed_at)
        with self._connect() as connection:
            cursor = connection.execute(
                "UPDATE events SET dismissed_at=? WHERE type='approval.required' "
                "AND dismissed_at IS NULL AND approval_id<>'' AND EXISTS ("
                "SELECT 1 FROM approvals WHERE approvals.approval_id=events.approval_id "
                "AND (approvals.status<>'pending' OR approvals.expires_at<=?))",
                (dismissed, current),
            )
            return cursor.rowcount

    def dismiss_gateway_lifecycle_events(
        self,
        *,
        dismissed_at: int | None = None,
    ) -> int:
        with self._connect() as connection:
            rows = connection.execute(
                "SELECT event_id, detail_json FROM events WHERE type='channel.message' "
                "AND dismissed_at IS NULL"
            ).fetchall()
            event_ids = []
            for row in rows:
                detail = _load_json(row["detail_json"], {})
                message = str(detail.get("message") or "").strip()
                if any(message.startswith(prefix) for prefix in _GATEWAY_LIFECYCLE_PREFIXES):
                    event_ids.append(str(row["event_id"]))
            return self._dismiss_event_ids(
                connection,
                event_ids,
                dismissed_at=dismissed_at,
            )

    @staticmethod
    def _dismiss_event_ids(
        connection: sqlite3.Connection,
        event_ids: Iterable[str],
        *,
        dismissed_at: int | None = None,
    ) -> int:
        ids = tuple(dict.fromkeys(str(event_id) for event_id in event_ids if event_id))
        if not ids:
            return 0
        cursor = connection.execute(
            "UPDATE events SET dismissed_at=? WHERE dismissed_at IS NULL AND event_id IN ({})".format(
                ",".join("?" for _ in ids)
            ),
            (
                int(time.time()) if dismissed_at is None else int(dismissed_at),
                *ids,
            ),
        )
        return cursor.rowcount
