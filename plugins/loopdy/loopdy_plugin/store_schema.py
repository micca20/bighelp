"""SQLite connection ownership and compatibility migrations. Keep migration SQL intact."""

from __future__ import annotations

import hashlib
import json
import sqlite3
import time
from contextlib import contextmanager
from .store_values import (
    _json,
)


class StoreSchema:
    def _ensure_schema(self) -> None:
        if self._initialized:
            return
        with self._init_lock:
            if self._initialized:
                return
            self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            with self._connect(initialize=False) as connection:
                connection.executescript(
                    """
                    CREATE TABLE IF NOT EXISTS turn_durations (
                        session_id TEXT NOT NULL,
                        turn_id TEXT NOT NULL,
                        final_timestamp REAL NOT NULL,
                        duration_ms INTEGER NOT NULL CHECK(duration_ms >= 0),
                        PRIMARY KEY (session_id, turn_id)
                    );
                    CREATE TABLE IF NOT EXISTS metadata (
                        key TEXT PRIMARY KEY,
                        value TEXT NOT NULL
                    );
                    CREATE TABLE IF NOT EXISTS devices (
                        device_id TEXT PRIMARY KEY,
                        endpoint_id TEXT NOT NULL UNIQUE,
                        provider TEXT NOT NULL DEFAULT 'managed',
                        token_environment TEXT NOT NULL DEFAULT 'production',
                        label TEXT NOT NULL,
                        groups_json TEXT NOT NULL,
                        preferences_json TEXT NOT NULL,
                        created_at INTEGER NOT NULL,
                        updated_at INTEGER NOT NULL,
                        revoked_at INTEGER,
                        recipient_public_key TEXT NOT NULL DEFAULT '',
                        recipient_key_id TEXT NOT NULL DEFAULT '',
                        revision INTEGER NOT NULL DEFAULT 0,
                        lease_expires INTEGER NOT NULL DEFAULT 0,
                        normalized_body_digest TEXT NOT NULL DEFAULT '',
                        sender_key_revision INTEGER NOT NULL DEFAULT 0,
                        acknowledged_sender_key_ids_json TEXT NOT NULL DEFAULT '[]',
                        sender_ack_body_digest TEXT NOT NULL DEFAULT '',
                        relay_generation INTEGER NOT NULL DEFAULT 0
                    );
                    CREATE TABLE IF NOT EXISTS events (
                        event_id TEXT PRIMARY KEY,
                        type TEXT NOT NULL,
                        status TEXT NOT NULL,
                        target TEXT NOT NULL,
                        profile TEXT NOT NULL,
                        session_id TEXT NOT NULL,
                        job_id TEXT NOT NULL,
                        task_id TEXT NOT NULL,
                        approval_id TEXT NOT NULL,
                        delegation_id TEXT NOT NULL,
                        detail_json TEXT NOT NULL,
                        push_json TEXT NOT NULL,
                        created_at INTEGER NOT NULL,
                        delivered_at INTEGER,
                        delivery_id TEXT,
                        failure TEXT,
                        dismissed_at INTEGER,
                        read_at INTEGER,
                        pinned_at INTEGER
                    );
                    CREATE TABLE IF NOT EXISTS approvals (
                        approval_id TEXT PRIMARY KEY,
                        request_digest TEXT NOT NULL,
                        allowed_choices_json TEXT NOT NULL,
                        event_id TEXT NOT NULL,
                        status TEXT NOT NULL,
                        choice TEXT,
                        expires_at INTEGER NOT NULL,
                        created_at INTEGER NOT NULL,
                        responded_at INTEGER
                    );
                    CREATE TABLE IF NOT EXISTS event_deliveries (
                        event_id TEXT NOT NULL,
                        device_id TEXT NOT NULL,
                        provider TEXT NOT NULL,
                        status TEXT NOT NULL,
                        attempts INTEGER NOT NULL,
                        delivery_id TEXT NOT NULL,
                        failure TEXT NOT NULL,
                        created_at INTEGER NOT NULL,
                        updated_at INTEGER NOT NULL,
                        target_revision INTEGER NOT NULL DEFAULT 0,
                        target_generation INTEGER NOT NULL DEFAULT 0,
                        target_key_id TEXT NOT NULL DEFAULT '',
                        target_sender_key_id TEXT NOT NULL DEFAULT '',
                        relay_request_body_json TEXT NOT NULL DEFAULT '',
                        next_attempt_at INTEGER NOT NULL DEFAULT 0,
                        claim_token TEXT NOT NULL DEFAULT '',
                        claim_expires INTEGER NOT NULL DEFAULT 0,
                        PRIMARY KEY (event_id, device_id)
                    );
                    CREATE TABLE IF NOT EXISTS provider_receipts (
                        receipt_id TEXT PRIMARY KEY,
                        event_id TEXT NOT NULL,
                        device_id TEXT NOT NULL,
                        provider TEXT NOT NULL,
                        status TEXT NOT NULL,
                        created_at INTEGER NOT NULL,
                        checked_at INTEGER,
                        error TEXT NOT NULL
                    );
                    CREATE TABLE IF NOT EXISTS live_activities (
                        activity_id TEXT PRIMARY KEY,
                        session_id TEXT NOT NULL,
                        live_session_id TEXT NOT NULL,
                        profile TEXT NOT NULL,
                        push_token TEXT NOT NULL,
                        token_environment TEXT NOT NULL,
                        created_at INTEGER NOT NULL,
                        updated_at INTEGER NOT NULL,
                        last_push_timestamp INTEGER NOT NULL DEFAULT 0,
                        owner_generation INTEGER NOT NULL DEFAULT 0,
                        ended_at INTEGER
                    );
                    CREATE INDEX IF NOT EXISTS live_activities_session_idx
                    ON live_activities(live_session_id, session_id, ended_at);
                    CREATE TABLE IF NOT EXISTS pending_live_activity_updates (
                        activity_id TEXT PRIMARY KEY,
                        status TEXT NOT NULL,
                        detail TEXT NOT NULL,
                        tool_name TEXT NOT NULL,
                        active_session_count INTEGER NOT NULL,
                        attempts INTEGER NOT NULL,
                        next_attempt_at INTEGER NOT NULL,
                        last_error TEXT NOT NULL,
                        updated_at INTEGER NOT NULL,
                        terminal INTEGER NOT NULL DEFAULT 0,
                        owner_session_id TEXT NOT NULL DEFAULT '',
                        owner_live_session_id TEXT NOT NULL DEFAULT '',
                        owner_profile TEXT NOT NULL DEFAULT '',
                        owner_push_token TEXT NOT NULL DEFAULT '',
                        owner_generation INTEGER NOT NULL DEFAULT 0,
                        request_id TEXT NOT NULL DEFAULT ''
                    );
                    CREATE INDEX IF NOT EXISTS pending_live_activity_updates_due_idx
                    ON pending_live_activity_updates(next_attempt_at);
                    CREATE TABLE IF NOT EXISTS pending_relay_live_activity_updates (
                        activity_id TEXT PRIMARY KEY,
                        status TEXT NOT NULL,
                        detail TEXT NOT NULL,
                        tool_name TEXT NOT NULL,
                        active_session_count INTEGER NOT NULL,
                        attempts INTEGER NOT NULL,
                        next_attempt_at INTEGER NOT NULL,
                        last_error TEXT NOT NULL,
                        updated_at INTEGER NOT NULL,
                        timestamp INTEGER NOT NULL DEFAULT 0,
                        delivery_id TEXT NOT NULL DEFAULT '',
                        idempotency_key TEXT NOT NULL DEFAULT '',
                        request_body_json TEXT NOT NULL DEFAULT '',
                        device_id TEXT NOT NULL DEFAULT '',
                        session_ref TEXT NOT NULL DEFAULT '',
                        revision INTEGER NOT NULL DEFAULT 0,
                        lease_expires INTEGER NOT NULL DEFAULT 0,
                        relay_generation INTEGER NOT NULL DEFAULT 0,
                        terminal INTEGER NOT NULL DEFAULT 0
                    );
                    CREATE INDEX IF NOT EXISTS pending_relay_live_activity_updates_due_idx
                    ON pending_relay_live_activity_updates(next_attempt_at);
                    CREATE TABLE IF NOT EXISTS pending_relay_operations (
                        operation TEXT NOT NULL,
                        device_id TEXT NOT NULL,
                        revision INTEGER NOT NULL,
                        idempotency_key TEXT NOT NULL,
                        body_json TEXT NOT NULL,
                        response_json TEXT NOT NULL DEFAULT '',
                        relay_generation INTEGER NOT NULL DEFAULT 0,
                        request_digest TEXT NOT NULL DEFAULT '',
                        attempts INTEGER NOT NULL,
                        updated_at INTEGER NOT NULL,
                        next_attempt_at INTEGER NOT NULL DEFAULT 0,
                        claim_token TEXT NOT NULL DEFAULT '',
                        claim_expires INTEGER NOT NULL DEFAULT 0,
                        terminal INTEGER NOT NULL DEFAULT 0,
                        last_error TEXT NOT NULL DEFAULT '',
                        row_version INTEGER NOT NULL DEFAULT 1,
                        PRIMARY KEY (operation, device_id)
                    );
                    CREATE TABLE IF NOT EXISTS relay_live_activities (
                        activity_id TEXT PRIMARY KEY,
                        device_id TEXT NOT NULL,
                        session_ref TEXT NOT NULL,
                        revision INTEGER NOT NULL,
                        source_timestamp INTEGER NOT NULL,
                        lease_expires INTEGER NOT NULL,
                        normalized_body_digest TEXT NOT NULL,
                        created_at INTEGER NOT NULL,
                        updated_at INTEGER NOT NULL,
                        last_push_timestamp INTEGER NOT NULL DEFAULT 0,
                        ended_at INTEGER,
                        revoked_at INTEGER
                    );
                    CREATE TABLE IF NOT EXISTS generative_ui_forms (
                        request_id TEXT PRIMARY KEY,
                        profile TEXT NOT NULL,
                        session_id TEXT NOT NULL,
                        form_schema_json TEXT NOT NULL,
                        content_hash TEXT NOT NULL,
                        state TEXT NOT NULL,
                        idempotency_key TEXT,
                        request_digest TEXT,
                        values_json TEXT,
                        response_json TEXT,
                        created_at INTEGER NOT NULL,
                        expires_at INTEGER NOT NULL,
                        submitted_at INTEGER,
                        consumed_at INTEGER
                    );
                    CREATE INDEX IF NOT EXISTS generative_ui_forms_owner_idx
                    ON generative_ui_forms(profile, session_id, state, expires_at);
                    CREATE TABLE IF NOT EXISTS card_templates (
                        profile TEXT NOT NULL,
                        template_id TEXT NOT NULL,
                        version INTEGER NOT NULL,
                        name TEXT NOT NULL,
                        summary TEXT NOT NULL,
                        sha256 TEXT NOT NULL,
                        template_json TEXT NOT NULL,
                        created_at INTEGER NOT NULL,
                        updated_at INTEGER NOT NULL,
                        PRIMARY KEY (profile, template_id)
                    );
                    CREATE INDEX IF NOT EXISTS card_templates_profile_name_idx
                    ON card_templates(profile, name, template_id);
                    """
                )
                event_columns = {
                    row[1] for row in connection.execute("PRAGMA table_info(events)").fetchall()
                }
                if "task_id" not in event_columns:
                    connection.execute(
                        "ALTER TABLE events ADD COLUMN task_id TEXT NOT NULL DEFAULT ''"
                    )
                if "dismissed_at" not in event_columns:
                    connection.execute(
                        "ALTER TABLE events ADD COLUMN dismissed_at INTEGER"
                    )
                if "read_at" not in event_columns:
                    connection.execute("ALTER TABLE events ADD COLUMN read_at INTEGER")
                if "pinned_at" not in event_columns:
                    connection.execute("ALTER TABLE events ADD COLUMN pinned_at INTEGER")
                device_columns = {
                    row[1] for row in connection.execute("PRAGMA table_info(devices)").fetchall()
                }
                migrated_legacy_devices = "provider" not in device_columns
                if "provider" not in device_columns:
                    connection.execute(
                        "ALTER TABLE devices ADD COLUMN provider TEXT NOT NULL "
                        "DEFAULT 'legacy_relay'"
                    )
                if "token_environment" not in device_columns:
                    connection.execute(
                        "ALTER TABLE devices ADD COLUMN token_environment TEXT NOT NULL DEFAULT ''"
                    )
                for column, declaration in (
                    ("recipient_public_key", "TEXT NOT NULL DEFAULT ''"),
                    ("recipient_key_id", "TEXT NOT NULL DEFAULT ''"),
                    ("revision", "INTEGER NOT NULL DEFAULT 0"),
                    ("lease_expires", "INTEGER NOT NULL DEFAULT 0"),
                    ("normalized_body_digest", "TEXT NOT NULL DEFAULT ''"),
                    ("sender_key_revision", "INTEGER NOT NULL DEFAULT 0"),
                    ("acknowledged_sender_key_ids_json", "TEXT NOT NULL DEFAULT '[]'"),
                    ("sender_ack_body_digest", "TEXT NOT NULL DEFAULT ''"),
                    ("relay_generation", "INTEGER NOT NULL DEFAULT 0"),
                ):
                    if column not in device_columns:
                        connection.execute(
                            f"ALTER TABLE devices ADD COLUMN {column} {declaration}"
                        )
                if migrated_legacy_devices:
                    now = int(time.time())
                    connection.execute(
                        "UPDATE devices SET revoked_at=COALESCE(revoked_at, ?), updated_at=? "
                        "WHERE provider='legacy_relay'",
                        (now, now),
                    )
                live_activity_columns = {
                    row[1]
                    for row in connection.execute("PRAGMA table_info(live_activities)").fetchall()
                }
                if "last_push_timestamp" not in live_activity_columns:
                    connection.execute(
                        "ALTER TABLE live_activities ADD COLUMN "
                        "last_push_timestamp INTEGER NOT NULL DEFAULT 0"
                    )
                if "owner_generation" not in live_activity_columns:
                    connection.execute(
                        "ALTER TABLE live_activities ADD COLUMN "
                        "owner_generation INTEGER NOT NULL DEFAULT 0"
                    )
                relay_activity_columns = {
                    row[1]
                    for row in connection.execute(
                        "PRAGMA table_info(relay_live_activities)"
                    ).fetchall()
                }
                for column, declaration in (
                    ("last_push_timestamp", "INTEGER NOT NULL DEFAULT 0"),
                    ("ended_at", "INTEGER"),
                ):
                    if column not in relay_activity_columns:
                        connection.execute(
                            f"ALTER TABLE relay_live_activities ADD COLUMN {column} {declaration}"
                        )
                delivery_columns = {
                    row[1]
                    for row in connection.execute("PRAGMA table_info(event_deliveries)").fetchall()
                }
                for column, declaration in (
                    ("target_revision", "INTEGER NOT NULL DEFAULT 0"),
                    ("target_generation", "INTEGER NOT NULL DEFAULT 0"),
                    ("target_key_id", "TEXT NOT NULL DEFAULT ''"),
                    ("target_sender_key_id", "TEXT NOT NULL DEFAULT ''"),
                    ("relay_request_body_json", "TEXT NOT NULL DEFAULT ''"),
                    ("next_attempt_at", "INTEGER NOT NULL DEFAULT 0"),
                    ("claim_token", "TEXT NOT NULL DEFAULT ''"),
                    ("claim_expires", "INTEGER NOT NULL DEFAULT 0"),
                ):
                    if column not in delivery_columns:
                        connection.execute(
                            f"ALTER TABLE event_deliveries ADD COLUMN {column} {declaration}"
                        )
                connection.execute(
                    "DELETE FROM metadata WHERE key IN "
                    "('relay_url', 'credential', 'installation_id')"
                )
                relay_pending_columns = {
                    row[1]
                    for row in connection.execute(
                        "PRAGMA table_info(pending_relay_live_activity_updates)"
                    ).fetchall()
                }
                for column, declaration in (
                    ("timestamp", "INTEGER NOT NULL DEFAULT 0"),
                    ("delivery_id", "TEXT NOT NULL DEFAULT ''"),
                    ("idempotency_key", "TEXT NOT NULL DEFAULT ''"),
                    ("request_body_json", "TEXT NOT NULL DEFAULT ''"),
                    ("device_id", "TEXT NOT NULL DEFAULT ''"),
                    ("session_ref", "TEXT NOT NULL DEFAULT ''"),
                    ("revision", "INTEGER NOT NULL DEFAULT 0"),
                    ("lease_expires", "INTEGER NOT NULL DEFAULT 0"),
                    ("relay_generation", "INTEGER NOT NULL DEFAULT 0"),
                    ("terminal", "INTEGER NOT NULL DEFAULT 0"),
                ):
                    if column not in relay_pending_columns:
                        connection.execute(
                            f"ALTER TABLE pending_relay_live_activity_updates ADD COLUMN {column} {declaration}"
                        )
                direct_pending_columns = {
                    row[1]
                    for row in connection.execute(
                        "PRAGMA table_info(pending_live_activity_updates)"
                    ).fetchall()
                }
                for column, declaration in (
                    ("terminal", "INTEGER NOT NULL DEFAULT 0"),
                    ("owner_session_id", "TEXT NOT NULL DEFAULT ''"),
                    ("owner_live_session_id", "TEXT NOT NULL DEFAULT ''"),
                    ("owner_profile", "TEXT NOT NULL DEFAULT ''"),
                    ("owner_push_token", "TEXT NOT NULL DEFAULT ''"),
                    ("owner_generation", "INTEGER NOT NULL DEFAULT 0"),
                    ("request_id", "TEXT NOT NULL DEFAULT ''"),
                ):
                    if column not in direct_pending_columns:
                        connection.execute(
                            f"ALTER TABLE pending_live_activity_updates ADD COLUMN {column} {declaration}"
                        )
                # Existing direct rows predate owner/request CAS.  Rebind
                # only rows whose activity is still active; re-registration
                # already removes its old pending row before creating a new
                # owner, so this cannot revive stale work.
                connection.execute(
                    "UPDATE pending_live_activity_updates SET "
                    "owner_session_id=(SELECT session_id FROM live_activities WHERE live_activities.activity_id=pending_live_activity_updates.activity_id), "
                    "owner_live_session_id=(SELECT live_session_id FROM live_activities WHERE live_activities.activity_id=pending_live_activity_updates.activity_id), "
                    "owner_profile=(SELECT profile FROM live_activities WHERE live_activities.activity_id=pending_live_activity_updates.activity_id), "
                    "owner_push_token=(SELECT push_token FROM live_activities WHERE live_activities.activity_id=pending_live_activity_updates.activity_id) "
                    "WHERE owner_session_id='' AND EXISTS (SELECT 1 FROM live_activities "
                    "WHERE live_activities.activity_id=pending_live_activity_updates.activity_id "
                    "AND live_activities.ended_at IS NULL)"
                )
                connection.execute(
                    "UPDATE live_activities SET owner_generation=1 WHERE owner_generation=0"
                )
                connection.execute(
                    "UPDATE pending_live_activity_updates SET owner_generation=("
                    "SELECT owner_generation FROM live_activities "
                    "WHERE live_activities.activity_id=pending_live_activity_updates.activity_id"
                    ") WHERE owner_generation=0 AND EXISTS (SELECT 1 FROM live_activities "
                    "WHERE live_activities.activity_id=pending_live_activity_updates.activity_id)"
                )
                connection.execute(
                    "INSERT INTO metadata(key, value) VALUES ('schema_version', '8') "
                    "ON CONFLICT(key) DO UPDATE SET value='8'"
                )
                operation_columns = {
                    row[1]
                    for row in connection.execute(
                        "PRAGMA table_info(pending_relay_operations)"
                    ).fetchall()
                }
                for column, declaration in (
                    ("response_json", "TEXT NOT NULL DEFAULT ''"),
                    ("relay_generation", "INTEGER NOT NULL DEFAULT 0"),
                    ("request_digest", "TEXT NOT NULL DEFAULT ''"),
                    ("next_attempt_at", "INTEGER NOT NULL DEFAULT 0"),
                    ("claim_token", "TEXT NOT NULL DEFAULT ''"),
                    ("claim_expires", "INTEGER NOT NULL DEFAULT 0"),
                    ("terminal", "INTEGER NOT NULL DEFAULT 0"),
                    ("last_error", "TEXT NOT NULL DEFAULT ''"),
                    ("row_version", "INTEGER NOT NULL DEFAULT 1"),
                ):
                    if column not in operation_columns:
                        connection.execute(
                            f"ALTER TABLE pending_relay_operations ADD COLUMN {column} {declaration}"
                        )
                # Backfill the immutable request digest for valid legacy rows;
                # malformed rows remain quarantinable by the recovery owner.
                for legacy in connection.execute(
                    "SELECT operation, device_id, body_json FROM pending_relay_operations "
                    "WHERE request_digest=''"
                ).fetchall():
                    try:
                        parsed = json.loads(str(legacy["body_json"]))
                        digest = hashlib.sha256(_json(parsed).encode("utf-8")).hexdigest()
                    except (TypeError, ValueError, json.JSONDecodeError):
                        continue
                    connection.execute(
                        "UPDATE pending_relay_operations SET request_digest=? "
                        "WHERE operation=? AND device_id=? AND request_digest=''",
                        (digest, legacy["operation"], legacy["device_id"]),
                    )
                connection.execute(
                    "INSERT OR IGNORE INTO metadata(key, value) VALUES ('provider_mode', ?)",
                    ("managed" if migrated_legacy_devices else "relay",),
                )
                # v2.1 used both spellings for the device revoke route.  Keep
                # one durable key so aliases cannot create two operations.
                connection.execute(
                    "UPDATE pending_relay_operations SET operation='revoke_device' "
                    "WHERE operation='device_revoke' AND NOT EXISTS ("
                    "SELECT 1 FROM pending_relay_operations newer "
                    "WHERE newer.operation='revoke_device' "
                    "AND newer.device_id=pending_relay_operations.device_id)"
                )
                connection.execute(
                    "INSERT OR IGNORE INTO metadata(key, value) "
                    "VALUES ('relay_config_generation', '0')"
                )
                connection.execute(
                    "INSERT OR IGNORE INTO metadata(key, value) "
                    "VALUES ('relay_config_state', 'enabled')"
                )
                connection.execute(
                    "CREATE INDEX IF NOT EXISTS pending_relay_operations_due_idx "
                    "ON pending_relay_operations(terminal, next_attempt_at, claim_expires)"
                )
                connection.execute(
                    "CREATE INDEX IF NOT EXISTS event_deliveries_relay_due_idx "
                    "ON event_deliveries(provider, status, next_attempt_at, claim_expires)"
                )
            try:
                self.path.chmod(0o600)
            except OSError:
                pass
            self._initialized = True

    @contextmanager
    def _connect(self, *, initialize: bool = True):
        if initialize:
            self._ensure_schema()
        connection = sqlite3.connect(self.path, timeout=5)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA busy_timeout=5000")
        try:
            yield connection
            connection.commit()
        except BaseException:
            connection.rollback()
            raise
        finally:
            connection.close()

    @staticmethod
    def _metadata_integer(connection: sqlite3.Connection, key: str, default: int) -> int:
        row = connection.execute("SELECT value FROM metadata WHERE key=?", (key,)).fetchone()
        if row is None:
            return default
        try:
            value = int(row["value"])
        except (TypeError, ValueError):
            return default
        return max(0, value)

    @staticmethod
    def _assert_relay_generation(
        connection: sqlite3.Connection,
        expected: int | None,
        current: int,
    ) -> None:
        if expected is not None and int(expected) != current:
            raise ValueError("Relay configuration generation changed")
