"""Approval, form and card-template persistence with profile/request binding."""

from __future__ import annotations

import hashlib
import hmac
import json
import time
from typing import Any, Iterable, Mapping
from .loopdy_cards import canonical_json as canonical_card_json
from .store_values import (
    CardTemplateConflict,
    CardTemplateLimit,
    _card_template,
    _card_template_hash,
    _card_template_id,
    _content_hash,
    _form_request_id,
    _form_response,
    _form_row,
    _idempotency_key,
    _identifier,
    _json,
    _load_json,
    _positive_revision,
    _required_text,
    _same_owner,
)


class InteractionStore:
    def install_card_template(
        self,
        *,
        profile: str,
        template: Mapping[str, Any],
    ) -> dict[str, Any]:
        owner = _identifier(profile, "profile")
        normalized = _card_template(template)
        now = int(time.time())
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            existing = connection.execute(
                "SELECT version, sha256, template_json FROM card_templates "
                "WHERE profile=? AND template_id=?",
                (owner, normalized["id"]),
            ).fetchone()
            if existing is not None:
                current_version = int(existing["version"])
                if normalized["version"] < current_version:
                    raise CardTemplateConflict("Card template version cannot decrease")
                if normalized["version"] == current_version:
                    if (
                        hmac.compare_digest(str(existing["sha256"]), normalized["sha256"])
                        and hmac.compare_digest(
                            str(existing["template_json"]),
                            canonical_card_json(normalized),
                        )
                    ):
                        return {"changed": False, "template": normalized}
                    raise CardTemplateConflict("Card template version conflict")
            connection.execute(
                """
                INSERT INTO card_templates (
                    profile, template_id, version, name, summary, sha256,
                    template_json, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(profile, template_id) DO UPDATE SET
                    version=excluded.version,
                    name=excluded.name,
                    summary=excluded.summary,
                    sha256=excluded.sha256,
                    template_json=excluded.template_json,
                    updated_at=excluded.updated_at
                """,
                (
                    owner,
                    normalized["id"],
                    normalized["version"],
                    normalized["name"],
                    normalized["summary"],
                    normalized["sha256"],
                    canonical_card_json(normalized),
                    now,
                    now,
                ),
            )
        return {"changed": True, "template": normalized}

    def list_card_templates(self, *, profile: str, limit: int | None = None) -> list[dict[str, Any]]:
        owner = _identifier(profile, "profile")
        if limit is not None and (type(limit) is not int or not 1 <= limit <= 500):
            raise ValueError("Card template catalog limit is invalid")
        with self._connect() as connection:
            rows = connection.execute(
                "SELECT template_json FROM card_templates WHERE profile=? "
                "ORDER BY name COLLATE NOCASE, template_id" + (" LIMIT ?" if limit is not None else ""),
                (owner, limit + 1) if limit is not None else (owner,),
            ).fetchall()
        if limit is not None and len(rows) > limit:
            raise CardTemplateLimit("Card template catalog exceeds the row limit")
        return [json.loads(str(row["template_json"])) for row in rows]

    def get_card_template(
        self,
        *,
        profile: str,
        template_id: str,
    ) -> dict[str, Any] | None:
        owner = _identifier(profile, "profile")
        identifier = _card_template_id(template_id)
        with self._connect() as connection:
            row = connection.execute(
                "SELECT template_json FROM card_templates WHERE profile=? AND template_id=?",
                (owner, identifier),
            ).fetchone()
        return None if row is None else json.loads(str(row["template_json"]))

    def remove_card_template(
        self,
        *,
        profile: str,
        template_id: str,
        version: int,
        sha256: str,
    ) -> dict[str, Any]:
        owner = _identifier(profile, "profile")
        identifier = _card_template_id(template_id)
        expected_version = _positive_revision(version)
        expected_hash = _card_template_hash(sha256)
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                "SELECT version, sha256 FROM card_templates WHERE profile=? AND template_id=?",
                (owner, identifier),
            ).fetchone()
            if row is None:
                return {"changed": False, "templateId": identifier}
            if int(row["version"]) != expected_version or not hmac.compare_digest(
                str(row["sha256"]), expected_hash
            ):
                raise CardTemplateConflict("Card template removal conflict")
            connection.execute(
                "DELETE FROM card_templates WHERE profile=? AND template_id=?",
                (owner, identifier),
            )
        return {"changed": True, "templateId": identifier}

    def create_approval(
        self,
        *,
        approval_id: str,
        request_digest: str,
        allowed_choices: Iterable[str],
        event_id: str,
        expires_at: int,
    ) -> None:
        choices = [str(choice) for choice in allowed_choices]
        if (
            not choices
            or len(choices) > 4
            or len(set(choices)) != len(choices)
            or not set(choices).issubset({"once", "session", "always", "deny"})
        ):
            raise ValueError("Loopdy approval choices are invalid")
        with self._connect() as connection:
            connection.execute(
                """
                INSERT INTO approvals (
                    approval_id, request_digest, allowed_choices_json, event_id,
                    status, choice, expires_at, created_at, responded_at
                ) VALUES (?, ?, ?, ?, 'pending', NULL, ?, ?, NULL)
                ON CONFLICT(approval_id) DO NOTHING
                """,
                (
                    _identifier(approval_id, "approval_id"),
                    _identifier(request_digest, "request_digest"),
                    _json(choices),
                    _identifier(event_id, "event_id"),
                    int(expires_at),
                    int(time.time()),
                ),
            )

    def respond_approval(self, approval_id: str, choice: str) -> bool:
        normalized = str(choice or "").strip().lower()
        if normalized not in {"once", "session", "always", "deny"}:
            raise ValueError("Loopdy approval response is invalid")
        now = int(time.time())
        with self._connect() as connection:
            row = connection.execute(
                "SELECT allowed_choices_json FROM approvals "
                "WHERE approval_id=? AND status='pending' AND expires_at>?",
                (str(approval_id), now),
            ).fetchone()
            if row is None:
                return False
            allowed = _load_json(row["allowed_choices_json"], [])
            if normalized not in allowed:
                raise ValueError("Approval choice was not offered by Hermes")
            cursor = connection.execute(
                "UPDATE approvals SET status='responded', choice=?, responded_at=? "
                "WHERE approval_id=? AND status='pending' AND expires_at>?",
                (normalized, now, str(approval_id), now),
            )
            return cursor.rowcount == 1

    def get_approval(self, approval_id: str) -> dict[str, Any] | None:
        now = int(time.time())
        with self._connect() as connection:
            connection.execute(
                "UPDATE approvals SET status='expired' "
                "WHERE approval_id=? AND status='pending' AND expires_at<=?",
                (str(approval_id), now),
            )
            row = connection.execute(
                "SELECT * FROM approvals WHERE approval_id=?", (str(approval_id),)
            ).fetchone()
        if row is None:
            return None
        return {
            "approval_id": row["approval_id"],
            "request_digest": row["request_digest"],
            "allowed_choices": _load_json(row["allowed_choices_json"], []),
            "event_id": row["event_id"],
            "status": row["status"],
            "choice": row["choice"],
            "expires_at": row["expires_at"],
        }

    def create_form_request(
        self,
        *,
        request_id: str,
        profile: str,
        session_id: str,
        form_schema: Mapping[str, Any],
        content_hash: str,
        created_at: int,
        expires_at: int,
    ) -> None:
        request = _form_request_id(request_id)
        owner_profile = _required_text(profile, "profile", 80)
        owner_session = _required_text(session_id, "session_id", 180)
        schema_json = _json(dict(form_schema))
        if len(schema_json.encode("utf-8")) > 32_768:
            raise ValueError("Form schema exceeds the byte limit")
        with self._connect() as connection:
            cursor = connection.execute(
                """
                INSERT INTO generative_ui_forms (
                    request_id, profile, session_id, form_schema_json, content_hash,
                    state, idempotency_key, request_digest, values_json,
                    response_json, created_at, expires_at, submitted_at, consumed_at
                ) VALUES (?, ?, ?, ?, ?, 'pending', NULL, NULL, NULL, NULL, ?, ?, NULL, NULL)
                ON CONFLICT(request_id) DO NOTHING
                """,
                (
                    request,
                    owner_profile,
                    owner_session,
                    schema_json,
                    _content_hash(content_hash),
                    int(created_at),
                    int(expires_at),
                ),
            )
            if cursor.rowcount != 1:
                raise ValueError("Form request ID collision")

    def get_form_request(self, request_id: str) -> dict[str, Any] | None:
        with self._connect() as connection:
            row = connection.execute(
                "SELECT * FROM generative_ui_forms WHERE request_id=?",
                (_form_request_id(request_id),),
            ).fetchone()
        return _form_row(row) if row is not None else None

    def submit_form_request(
        self,
        *,
        request_id: str,
        profile: str,
        session_id: str,
        idempotency_key: str,
        values: Mapping[str, Any],
        now: int | None = None,
    ) -> dict[str, Any]:
        request = _form_request_id(request_id)
        key = _idempotency_key(idempotency_key)
        owner_profile = _required_text(profile, "profile", 80)
        owner_session = _required_text(session_id, "session_id", 180)
        values_json = _json(dict(values))
        if len(values_json.encode("utf-8")) > 8_192:
            return _form_response(request, key, "error", "payload_too_large")
        digest = hashlib.sha256(
            _json(
                {
                    "kind": "submit_form",
                    "owner": {"profile": owner_profile, "session_id": owner_session},
                    "request_id": request,
                    "values": dict(values),
                }
            ).encode("utf-8")
        ).hexdigest()
        current = int(time.time()) if now is None else int(now)
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                "SELECT * FROM generative_ui_forms WHERE request_id=?", (request,)
            ).fetchone()
            if row is None:
                return _form_response(request, key, "error", "request_not_found")
            if not _same_owner(row, owner_profile, owner_session):
                return _form_response(request, key, "error", "owner_mismatch")
            if row["state"] == "pending" and int(row["expires_at"]) <= current:
                connection.execute(
                    "UPDATE generative_ui_forms SET state='expired' WHERE request_id=? AND state='pending'",
                    (request,),
                )
                return _form_response(request, key, "error", "request_expired")
            stored_key = str(row["idempotency_key"] or "")
            stored_digest = str(row["request_digest"] or "")
            if stored_key and hmac.compare_digest(stored_key, key):
                if hmac.compare_digest(stored_digest, digest):
                    replay = _load_json(row["response_json"], None)
                    return replay if isinstance(replay, dict) else _form_response(request, key, "success", "accepted")
                return _form_response(request, key, "error", "idempotency_conflict")
            if row["state"] == "submitted":
                return _form_response(request, key, "error", "already_submitted")
            if row["state"] == "consumed":
                return _form_response(request, key, "error", "already_consumed")
            if row["state"] == "expired":
                return _form_response(request, key, "error", "request_expired")
            response = _form_response(request, key, "success", "accepted")
            cursor = connection.execute(
                """
                UPDATE generative_ui_forms
                SET state='submitted', idempotency_key=?, request_digest=?, values_json=?,
                    response_json=?, submitted_at=?
                WHERE request_id=? AND state='pending' AND expires_at>?
                """,
                (key, digest, values_json, _json(response), current, request, current),
            )
            if cursor.rowcount != 1:
                return _form_response(request, key, "error", "already_submitted")
            return response

    def consume_form_response(
        self,
        *,
        request_id: str,
        profile: str,
        session_id: str,
        now: int | None = None,
    ) -> dict[str, Any]:
        request = _form_request_id(request_id)
        owner_profile = _required_text(profile, "profile", 80)
        owner_session = _required_text(session_id, "session_id", 180)
        current = int(time.time()) if now is None else int(now)
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                "SELECT * FROM generative_ui_forms WHERE request_id=?", (request,)
            ).fetchone()
            if row is None:
                return _form_response(request, "", "error", "request_not_found")
            if not _same_owner(row, owner_profile, owner_session):
                return _form_response(request, "", "error", "owner_mismatch")
            if row["state"] == "pending" and int(row["expires_at"]) <= current:
                connection.execute(
                    "UPDATE generative_ui_forms SET state='expired' WHERE request_id=? AND state='pending'",
                    (request,),
                )
                return _form_response(request, "", "error", "request_expired")
            if row["state"] == "pending":
                return _form_response(request, "", "pending", "accepted")
            if row["state"] == "expired":
                return _form_response(request, "", "error", "request_expired")
            if row["state"] == "consumed":
                return _form_response(request, str(row["idempotency_key"] or ""), "error", "already_consumed")
            values = _load_json(row["values_json"], None)
            if not isinstance(values, dict):
                return _form_response(request, str(row["idempotency_key"] or ""), "error", "internal_error")
            cursor = connection.execute(
                """
                UPDATE generative_ui_forms
                SET state='consumed', values_json=NULL, consumed_at=?
                WHERE request_id=? AND state='submitted'
                """,
                (current, request),
            )
            if cursor.rowcount != 1:
                return _form_response(request, str(row["idempotency_key"] or ""), "error", "already_consumed")
            return {
                **_form_response(request, str(row["idempotency_key"] or ""), "success", "accepted"),
                "values": values,
            }

    def form_request_status(
        self,
        request_id: str,
        *,
        profile: str,
        session_id: str,
        now: int | None = None,
    ) -> dict[str, Any]:
        request = _form_request_id(request_id)
        current = int(time.time()) if now is None else int(now)
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                "SELECT * FROM generative_ui_forms WHERE request_id=?", (request,)
            ).fetchone()
            if row is None:
                return _form_response(request, "", "error", "request_not_found")
            if not _same_owner(row, str(profile), str(session_id)):
                return _form_response(request, "", "error", "owner_mismatch")
            if row["state"] == "pending" and int(row["expires_at"]) <= current:
                connection.execute(
                    "UPDATE generative_ui_forms SET state='expired' WHERE request_id=? AND state='pending'",
                    (request,),
                )
                return _form_response(request, "", "error", "request_expired")
            code = {
                "pending": "accepted",
                "submitted": "accepted",
                "consumed": "already_consumed",
                "expired": "request_expired",
            }[row["state"]]
            state = "pending" if row["state"] == "pending" else ("success" if row["state"] == "submitted" else "error")
            return _form_response(request, str(row["idempotency_key"] or ""), state, code)
