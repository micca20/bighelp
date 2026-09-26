"""SQLite-backed Loopdy state, composed from explicit persistence domains.

All domains share this object's path, initialization lock and transactional
connection owner. Inheritance retains the existing LoopdyStore method API; it
does not create independent stores or dynamically register handlers.
"""

from __future__ import annotations

import errno
import hashlib
import hmac
import json
import os
import re
import sqlite3
import threading
import time
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Mapping
from .events import LoopdyEvent
from .loopdy_cards import canonical_json as canonical_card_json
from .loopdy_cards import validate_card_input

from .store_values import (
    CardTemplateConflict,
    CardTemplateLimit,
    _CLAIM_LEASE_SECONDS,
    _FORM_MESSAGES,
    _GATEWAY_LIFECYCLE_PREFIXES,
    _LEGACY_RELAY_PROVIDER_CONFLICT,
    _MAX_RELAY_AUTOMATIC_ATTEMPTS,
    _MAX_SAFE_REVISION,
    _MAX_TIMESTAMP,
    _PROTOCOL_IDENTIFIER,
    _UUID,
    _card_template,
    _card_template_hash,
    _card_template_id,
    _card_template_parameter_value,
    _card_template_parameters_schema,
    _content_hash,
    _delivery_status,
    _device_provider,
    _device_row,
    _event_row,
    _form_request_id,
    _form_response,
    _form_row,
    _idempotency_key,
    _identifier,
    _json,
    _load_json,
    _lock_file_descriptor,
    _normalized_body_digest,
    _positive_integer,
    _positive_revision,
    _protocol_identifier,
    _provider_mode,
    _relay_operation_name,
    _required_text,
    _same_owner,
    _text,
    _unlock_file_descriptor,
    form_action_response,
)
from .store_schema import StoreSchema
from .store_relay_devices import RelayDeviceStore
from .store_relay_activities import RelayActivityStore
from .store_relay_operations import RelayOperationStore
from .store_relay_deliveries import RelayDeliveryStore
from .store_live_activities import LiveActivityStore
from .store_interactions import InteractionStore
from .store_events import EventStore


class LoopdyStore(
    StoreSchema,
    RelayDeviceStore,
    RelayActivityStore,
    RelayOperationStore,
    RelayDeliveryStore,
    LiveActivityStore,
    InteractionStore,
    EventStore,
):
    def __init__(self, path: Path | str):
        self.path = Path(path)
        self._init_lock = threading.Lock()
        self._initialized = False
        self._ensure_schema()

    def upsert_device(
        self,
        *,
        device_id: str,
        endpoint_id: str,
        provider: str = "managed",
        token_environment: str = "production",
        label: str = "",
        groups: Iterable[str] = (),
        preferences: Mapping[str, Any] | None = None,
    ) -> None:
        now = int(time.time())
        normalized_groups = sorted({str(value).strip() for value in groups if str(value).strip()})
        normalized_provider = _device_provider(provider)
        normalized_environment = _text(token_environment, 32) or "production"
        normalized_preferences = None if preferences is None else dict(preferences)
        with self._connect() as connection:
            existing = connection.execute(
                "SELECT provider FROM devices WHERE device_id=?",
                (_identifier(device_id, "device_id"),),
            ).fetchone()
            if existing is not None and existing["provider"] == "relay" and normalized_provider != "relay":
                self._cancel_relay_device_work(connection, str(device_id), int(time.time()))
            connection.execute(
                """
                INSERT INTO devices (
                    device_id, endpoint_id, provider, token_environment, label,
                    groups_json, preferences_json, created_at, updated_at, revoked_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                ON CONFLICT(device_id) DO UPDATE SET
                    endpoint_id=excluded.endpoint_id,
                    provider=excluded.provider,
                    token_environment=excluded.token_environment,
                    label=excluded.label,
                    groups_json=excluded.groups_json,
                    preferences_json=CASE WHEN ? IS NULL THEN devices.preferences_json ELSE excluded.preferences_json END,
                    updated_at=excluded.updated_at,
                    revoked_at=NULL
                """,
                (
                    _identifier(device_id, "device_id"),
                    _required_text(endpoint_id, "endpoint_id", 512),
                    normalized_provider,
                    normalized_environment,
                    _text(label, 120),
                    _json(normalized_groups),
                    _json(normalized_preferences if normalized_preferences is not None else {}),
                    now,
                    now,
                    _json(normalized_preferences) if normalized_preferences is not None else None,
                ),
            )

    def update_preferences(self, device_id: str, preferences: Mapping[str, Any]) -> bool:
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                "SELECT preferences_json FROM devices "
                "WHERE device_id=? AND revoked_at IS NULL",
                (_identifier(device_id, "device_id"),),
            ).fetchone()
            if row is None:
                return False
            current = _load_json(row["preferences_json"], {})
            merged = dict(current) if isinstance(current, dict) else {}
            merged.update(dict(preferences))
            cursor = connection.execute(
                "UPDATE devices SET preferences_json=?, updated_at=? "
                "WHERE device_id=? AND revoked_at IS NULL",
                (_json(merged), int(time.time()), _identifier(device_id, "device_id")),
            )
            return cursor.rowcount == 1

    def revoke_device(self, device_id: str) -> bool:
        with self._connect() as connection:
            cursor = connection.execute(
                "UPDATE devices SET revoked_at=?, updated_at=? "
                "WHERE device_id=? AND revoked_at IS NULL",
                (
                    int(time.time()),
                    int(time.time()),
                    _identifier(device_id, "device_id"),
                ),
            )
            return cursor.rowcount == 1

    def list_devices(self) -> list[dict[str, Any]]:
        with self._connect() as connection:
            rows = connection.execute(
                "SELECT device_id, endpoint_id, provider, token_environment, label, "
                "groups_json, preferences_json, revoked_at, recipient_public_key, "
                "recipient_key_id, revision, lease_expires, sender_key_revision, "
                "acknowledged_sender_key_ids_json, relay_generation "
                "FROM devices ORDER BY device_id"
            ).fetchall()
        relay_enabled = self.relay_config_enabled()
        devices = [_device_row(row) for row in rows]
        if not relay_enabled:
            for device in devices:
                if device["provider"] == "relay":
                    device["revoked"] = True
        return devices

    def resolve_devices(
        self,
        target: str,
        provider: str | None = None,
        *,
        now: int | None = None,
    ) -> list[dict[str, Any]]:
        normalized_provider = None if provider is None else _device_provider(provider)
        current_time = int(time.time()) if now is None else _positive_integer(now, "now")
        relay_generation = self.relay_config_generation()
        relay_enabled = self.relay_config_enabled()
        value = str(target or "").strip()
        if value == "all":
            device_id = ""
            group = ""
        elif value.startswith("device:"):
            device_id = _identifier(value.split(":", 1)[1], "device_id")
            group = ""
        elif value.startswith("group:"):
            device_id = ""
            group = _identifier(value.split(":", 1)[1], "group_id")
        else:
            raise ValueError("Loopdy target must be all, device:<id>, or group:<id>")
        devices = [
            item
            for item in self.list_devices()
            if not item["revoked"]
            and (normalized_provider is None or item["provider"] == normalized_provider)
            and (
                item["provider"] != "relay"
                or (
                    relay_enabled
                    and int(item.get("relay_generation") or 0) == relay_generation
                    and int(item.get("lease_expires") or 0) > current_time
                    and bool(item.get("acknowledged_sender_key_ids"))
                )
            )
        ]
        if device_id:
            return [item for item in devices if item["device_id"] == device_id]
        if group:
            return [item for item in devices if group in item["groups"]]
        return devices

    def provider_mode(self) -> str:
        with self._connect() as connection:
            row = connection.execute(
                "SELECT value FROM metadata WHERE key='provider_mode'"
            ).fetchone()
        return _provider_mode(row["value"] if row is not None else "managed")

    def set_provider_mode(self, mode: str) -> None:
        requested = str(mode or "").strip().lower()
        if requested not in {"managed", "direct"}:
            raise ValueError("Loopdy provider mode must be managed or direct")
        with self._connect() as connection:
            connection.execute(
                "INSERT INTO metadata(key, value) VALUES ('provider_mode', ?) "
                "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                (requested,),
            )

    def retire_legacy_relay(self) -> bool:
        """Atomically remove persisted Cloudflare relay delivery state."""
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            mode = connection.execute(
                "SELECT value FROM metadata WHERE key='provider_mode'"
            ).fetchone()
            has_config = connection.execute(
                "SELECT 1 FROM metadata WHERE key='relay_config_v1'"
            ).fetchone() is not None
            has_devices = connection.execute(
                "SELECT 1 FROM devices WHERE provider IN ('relay', 'legacy_relay') LIMIT 1"
            ).fetchone() is not None
            has_activity = connection.execute(
                "SELECT 1 FROM relay_live_activities LIMIT 1"
            ).fetchone() is not None
            has_operations = connection.execute(
                "SELECT 1 FROM pending_relay_operations LIMIT 1"
            ).fetchone() is not None
            has_updates = connection.execute(
                "SELECT 1 FROM pending_relay_live_activity_updates LIMIT 1"
            ).fetchone() is not None
            has_deliveries = connection.execute(
                "SELECT 1 FROM event_deliveries WHERE provider='relay' LIMIT 1"
            ).fetchone() is not None
            if not any((has_config, has_devices, has_activity, has_operations, has_updates,
                        has_deliveries, mode is not None and str(mode["value"]) == "relay")):
                return False
            generation = self._metadata_integer(connection, "relay_config_generation", 0) + 1
            connection.execute("DELETE FROM event_deliveries WHERE provider='relay'")
            connection.execute("DELETE FROM provider_receipts WHERE provider='relay'")
            connection.execute("DELETE FROM pending_relay_live_activity_updates")
            connection.execute("DELETE FROM pending_relay_operations")
            connection.execute("DELETE FROM relay_live_activities")
            connection.execute("DELETE FROM devices WHERE provider IN ('relay', 'legacy_relay')")
            connection.execute("DELETE FROM metadata WHERE key='relay_config_v1'")
            connection.execute(
                "INSERT INTO metadata(key, value) VALUES ('provider_mode', 'managed') "
                "ON CONFLICT(key) DO UPDATE SET value='managed'"
            )
            connection.execute(
                "INSERT INTO metadata(key, value) VALUES ('relay_config_generation', ?) "
                "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                (str(generation),),
            )
            connection.execute(
                "INSERT INTO metadata(key, value) VALUES ('relay_config_state', 'disabled') "
                "ON CONFLICT(key) DO UPDATE SET value='disabled'"
            )
            return True

    def save_apns_config(self, config: Mapping[str, Any]) -> None:
        allowed = {"team_id", "key_id", "topic", "environment", "key_path"}
        value = {key: str(config.get(key) or "").strip() for key in sorted(allowed)}
        if any(not value[key] for key in allowed):
            raise ValueError("APNs configuration is incomplete")
        with self._connect() as connection:
            connection.execute(
                "INSERT INTO metadata(key, value) VALUES ('apns_config', ?) "
                "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                (_json(value),),
            )

    def load_apns_config(self) -> dict[str, str] | None:
        with self._connect() as connection:
            row = connection.execute(
                "SELECT value FROM metadata WHERE key='apns_config'"
            ).fetchone()
        if row is None:
            return None
        value = _load_json(row["value"], None)
        if not isinstance(value, dict):
            return None
        return {str(key): str(item) for key, item in value.items()}

    def clear_apns_config(self) -> None:
        with self._connect() as connection:
            connection.execute("DELETE FROM metadata WHERE key='apns_config'")

    def get_device(self, device_id: str) -> dict[str, Any] | None:
        identifier = _identifier(device_id, "device_id")
        with self._connect() as connection:
            row = connection.execute(
                "SELECT device_id, endpoint_id, provider, token_environment, label, "
                "groups_json, preferences_json, revoked_at, recipient_public_key, "
                "recipient_key_id, revision, lease_expires, sender_key_revision, "
                "acknowledged_sender_key_ids_json, relay_generation FROM devices WHERE device_id=?",
                (identifier,),
            ).fetchone()
        if row is None:
            return None
        result = _device_row(row)
        if result["provider"] == "relay" and not self.relay_config_enabled():
            result["revoked"] = True
        return result

    def record_device_delivery(
        self,
        *,
        event_id: str,
        device_id: str,
        provider: str,
        status: str,
        delivery_id: str = "",
        failure: str = "",
        target_revision: int = 0,
        target_generation: int = 0,
        target_key_id: str = "",
        target_sender_key_id: str = "",
        relay_request_body: Mapping[str, Any] | None = None,
    ) -> None:
        now = int(time.time())
        normalized_relay_body = "" if relay_request_body is None else _json(relay_request_body)
        with self._connect() as connection:
            connection.execute(
                """
                INSERT INTO event_deliveries (
                    event_id, device_id, provider, status, attempts, delivery_id,
                    failure, created_at, updated_at, target_revision, target_key_id,
                    target_generation, target_sender_key_id, relay_request_body_json
                ) VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(event_id, device_id) DO UPDATE SET
                    provider=excluded.provider,
                    status=excluded.status,
                    attempts=event_deliveries.attempts + 1,
                    delivery_id=excluded.delivery_id,
                    failure=excluded.failure,
                    updated_at=excluded.updated_at,
                    target_generation=CASE
                        WHEN event_deliveries.target_generation != excluded.target_generation
                        THEN excluded.target_generation
                        WHEN event_deliveries.target_generation=0 THEN excluded.target_generation
                        ELSE event_deliveries.target_generation
                    END,
                    target_revision=CASE
                        WHEN event_deliveries.target_generation != excluded.target_generation
                          OR event_deliveries.target_revision != excluded.target_revision
                        THEN excluded.target_revision
                        WHEN event_deliveries.target_revision=0 THEN excluded.target_revision
                        ELSE event_deliveries.target_revision
                    END,
                    target_key_id=CASE
                        WHEN event_deliveries.target_generation != excluded.target_generation
                          OR event_deliveries.target_revision != excluded.target_revision
                        THEN excluded.target_key_id
                        WHEN event_deliveries.target_key_id='' THEN excluded.target_key_id
                        ELSE event_deliveries.target_key_id
                    END,
                    target_sender_key_id=CASE
                        WHEN event_deliveries.target_generation != excluded.target_generation
                          OR event_deliveries.target_revision != excluded.target_revision
                        THEN excluded.target_sender_key_id
                        WHEN event_deliveries.target_sender_key_id='' THEN excluded.target_sender_key_id
                        ELSE event_deliveries.target_sender_key_id
                    END,
                    relay_request_body_json=CASE
                        WHEN event_deliveries.target_generation != excluded.target_generation
                          OR event_deliveries.target_revision != excluded.target_revision
                        THEN excluded.relay_request_body_json
                        WHEN excluded.relay_request_body_json='' THEN event_deliveries.relay_request_body_json
                        ELSE excluded.relay_request_body_json
                    END,
                    next_attempt_at=0,
                    claim_token='',
                    claim_expires=0
                """,
                (
                    _identifier(event_id, "event_id"),
                    _identifier(device_id, "device_id"),
                    _device_provider(provider),
                    _delivery_status(status),
                    _text(delivery_id, 180),
                    _text(failure, 500),
                    now,
                    now,
                    max(0, int(target_revision)),
                    _text(target_key_id, 64),
                    max(0, int(target_generation)),
                    _text(target_sender_key_id, 64),
                    normalized_relay_body,
                ),
            )

    def list_event_deliveries(self, event_id: str) -> list[dict[str, Any]]:
        with self._connect() as connection:
            rows = connection.execute(
                "SELECT * FROM event_deliveries WHERE event_id=? ORDER BY device_id",
                (_identifier(event_id, "event_id"),),
            ).fetchall()
        return [dict(row) for row in rows]

    def record_provider_receipt(
        self,
        *,
        receipt_id: str,
        event_id: str,
        device_id: str,
        provider: str,
    ) -> None:
        with self._connect() as connection:
            connection.execute(
                """
                INSERT OR IGNORE INTO provider_receipts (
                    receipt_id, event_id, device_id, provider, status,
                    created_at, checked_at, error
                ) VALUES (?, ?, ?, ?, 'pending', ?, NULL, '')
                """,
                (
                    _identifier(receipt_id, "receipt_id"),
                    _identifier(event_id, "event_id"),
                    _identifier(device_id, "device_id"),
                    _device_provider(provider),
                    int(time.time()),
                ),
            )

    def pending_provider_receipts(
        self,
        provider: str,
        *,
        limit: int = 1000,
    ) -> list[dict[str, Any]]:
        bounded = min(1000, max(1, int(limit)))
        with self._connect() as connection:
            rows = connection.execute(
                "SELECT * FROM provider_receipts "
                "WHERE provider=? AND status='pending' ORDER BY created_at LIMIT ?",
                (_device_provider(provider), bounded),
            ).fetchall()
        return [dict(row) for row in rows]

    def complete_provider_receipt(
        self,
        receipt_id: str,
        *,
        status: str,
        error: str = "",
    ) -> bool:
        normalized = str(status or "").strip().lower()
        if normalized not in {"delivered", "failed"}:
            raise ValueError("Provider receipt status must be delivered or failed")
        with self._connect() as connection:
            cursor = connection.execute(
                "UPDATE provider_receipts SET status=?, checked_at=?, error=? "
                "WHERE receipt_id=? AND status='pending'",
                (
                    normalized,
                    int(time.time()),
                    _text(error, 500),
                    _identifier(receipt_id, "receipt_id"),
                ),
            )
            return cursor.rowcount == 1
