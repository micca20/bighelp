"""Picker, personality, command catalog and session-fork protocol contracts."""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import re
from dataclasses import dataclass
from typing import Any

from .protocol_values import (
    _activity_label, _b64url, _label, _nonnegative, _opaque,
    _picker_identifier, _positive, _session_coordinate, _validate_envelope,
)

@dataclass(frozen=True)
class PickerOpen:
    request_id: str
    session_id: str
    agent_id: str
    kind: str
    sent_at: int

    def wire_value(self) -> dict[str, Any]:
        return {
            "version": 1,
            "type": "picker.open",
            "requestId": self.request_id,
            "sessionId": self.session_id,
            "agentId": self.agent_id,
            "kind": self.kind,
            "sentAt": self.sent_at,
        }


@dataclass(frozen=True)
class PickerSelection:
    picker_id: str
    session_id: str
    kind: str
    sent_at: int
    provider: str | None = None
    model: str | None = None
    value: str | None = None

    def wire_value(self) -> dict[str, Any]:
        result: dict[str, Any] = {
            "version": 1,
            "type": "picker.select",
            "pickerId": self.picker_id,
            "sessionId": self.session_id,
            "kind": self.kind,
            "sentAt": self.sent_at,
        }
        if self.kind == "model":
            result["provider"] = self.provider
            result["model"] = self.model
        else:
            result["value"] = self.value
        return result


@dataclass(frozen=True)
class SessionForkRequest:
    request_id: str
    source_session_id: str
    fork_session_id: str
    agent_id: str
    actor_id: str
    actor_name: str
    device_name: str
    user_turn: int
    checkpoint_role: str
    checkpoint_digest: str
    title: str
    sent_at: int

    def wire_value(self) -> dict[str, Any]:
        return {
            "version": 1,
            "type": "session.fork.request",
            "requestId": self.request_id,
            "sourceSessionId": self.source_session_id,
            "forkSessionId": self.fork_session_id,
            "agentId": self.agent_id,
            "actorId": self.actor_id,
            "actorName": self.actor_name,
            "deviceName": self.device_name,
            "userTurn": self.user_turn,
            "checkpointRole": self.checkpoint_role,
            "checkpointDigest": self.checkpoint_digest,
            "title": self.title,
            "sentAt": self.sent_at,
        }


@dataclass(frozen=True)
class CommandCatalogRequest:
    request_id: str
    session_id: str
    agent_id: str
    sent_at: int

    def wire_value(self) -> dict[str, Any]:
        return {
            "version": 1,
            "type": "commands.catalog.request",
            "requestId": self.request_id,
            "sessionId": self.session_id,
            "agentId": self.agent_id,
            "sentAt": self.sent_at,
        }


@dataclass(frozen=True)
class PersonalityRequest:
    request_id: str
    action: str
    expected_revision: int | None
    name: str | None
    definition: dict[str, str] | None
    sent_at: int


def parse_personality_request(value: dict[str, Any]) -> PersonalityRequest:
    if not isinstance(value, dict) or value.get("version") != 1:
        raise ValueError("Loopdy Link personality request is invalid")
    request_type = value.get("type")
    if request_type == "personalities.catalog.request":
        if set(value) != {"version", "type", "requestId", "sentAt"}:
            raise ValueError("Loopdy Link personality request is invalid")
        return PersonalityRequest(
            request_id=_opaque(value.get("requestId"), "requestId", 16, 128),
            action="catalog",
            expected_revision=None,
            name=None,
            definition=None,
            sent_at=_positive(value.get("sentAt"), "sentAt"),
        )
    if request_type != "personalities.mutate":
        raise ValueError("Loopdy Link personality request is invalid")
    action = value.get("action")
    if action not in {"save", "delete", "activate"}:
        raise ValueError("Loopdy Link personality action is invalid")
    required = {"version", "type", "requestId", "action", "expectedRevision", "sentAt"}
    optional = {"name", "definition"}
    if not required.issubset(value) or not set(value).issubset(required | optional):
        raise ValueError("Loopdy Link personality request is invalid")
    expected_revision = _nonnegative(value.get("expectedRevision"), "expectedRevision")
    name: str | None = None
    definition: dict[str, str] | None = None
    if "name" in value:
        name = _personality_name(value.get("name"), allows_neutral=action == "activate")
    if action == "save":
        if name is None or "definition" not in value:
            raise ValueError("Loopdy Link personality save is invalid")
        definition = _personality_definition(value.get("definition"))
        if definition["name"] != name:
            raise ValueError("Loopdy Link personality save coordinates do not match")
    elif action == "delete":
        if name is None or "definition" in value:
            raise ValueError("Loopdy Link personality delete is invalid")
    elif "definition" in value:
        raise ValueError("Loopdy Link personality activation is invalid")
    return PersonalityRequest(
        request_id=_opaque(value.get("requestId"), "requestId", 16, 128),
        action=action,
        expected_revision=expected_revision,
        name=name,
        definition=definition,
        sent_at=_positive(value.get("sentAt"), "sentAt"),
    )


def personality_catalog_payload(
    *,
    request_id: str,
    catalog: dict[str, Any],
    sent_at: int,
) -> dict[str, Any]:
    personalities = catalog.get("personalities") if isinstance(catalog, dict) else None
    if not isinstance(personalities, list) or len(personalities) > 100:
        raise ValueError("Loopdy Link personality catalog is invalid")
    validated = []
    names = set()
    for raw in personalities:
        definition = _personality_definition(raw, response=True)
        if definition["name"] in names:
            raise ValueError("Loopdy Link personality catalog contains duplicates")
        names.add(definition["name"])
        validated.append(definition)
    active_name = _personality_name(catalog.get("activeName", ""), allows_neutral=True)
    if active_name and active_name not in names:
        raise ValueError("Loopdy Link active personality is unavailable")
    return {
        "version": 1,
        "type": "personalities.catalog",
        "requestId": _opaque(request_id, "requestId", 16, 128),
        "revision": _nonnegative(catalog.get("revision"), "revision"),
        "activeName": active_name or "",
        "personalities": validated,
        "sentAt": _positive(sent_at, "sentAt"),
    }


def parse_picker_open(value: dict[str, Any]) -> PickerOpen:
    expected = {
        "version",
        "type",
        "requestId",
        "sessionId",
        "agentId",
        "kind",
        "sentAt",
    }
    _validate_envelope(
        value, expected, "picker.open", "Loopdy Link picker request is invalid",
        strict_version=False,
    )
    if value.get("kind") not in {"model", "reasoning"}:
        raise ValueError("Loopdy Link picker request is invalid")
    return PickerOpen(
        request_id=_opaque(value.get("requestId"), "requestId", 16, 128),
        session_id=_session_coordinate(value.get("sessionId")),
        agent_id=_opaque(value.get("agentId"), "agentId", 1, 96),
        kind=str(value["kind"]),
        sent_at=_positive(value.get("sentAt"), "sentAt"),
    )


def parse_picker_selection(value: dict[str, Any]) -> PickerSelection:
    if not isinstance(value, dict):
        raise ValueError("Loopdy Link picker selection is invalid")
    kind = value.get("kind")
    common = {
        "version",
        "type",
        "pickerId",
        "sessionId",
        "kind",
        "sentAt",
    }
    expected = common | ({"provider", "model"} if kind == "model" else {"value"})
    _validate_envelope(
        value, expected, "picker.select", "Loopdy Link picker selection is invalid",
        strict_version=False,
    )
    if kind not in {"model", "reasoning"}:
        raise ValueError("Loopdy Link picker selection is invalid")
    provider = model = selected_value = None
    if kind == "model":
        provider = _picker_identifier(value.get("provider"), "provider", 1, 128)
        model = _model_picker_identifier(value.get("model"), "model", 1, 256)
    else:
        selected_value = _picker_identifier(value.get("value"), "value", 1, 64)
    return PickerSelection(
        picker_id=_opaque(value.get("pickerId"), "pickerId", 16, 128),
        session_id=_session_coordinate(value.get("sessionId")),
        kind=str(kind),
        provider=provider,
        model=model,
        value=selected_value,
        sent_at=_positive(value.get("sentAt"), "sentAt"),
    )


def parse_session_fork_request(value: dict[str, Any]) -> SessionForkRequest:
    expected = {
        "version",
        "type",
        "requestId",
        "sourceSessionId",
        "forkSessionId",
        "agentId",
        "actorId",
        "actorName",
        "deviceName",
        "userTurn",
        "checkpointRole",
        "checkpointDigest",
        "title",
        "sentAt",
    }
    _validate_envelope(
        value, expected, "session.fork.request", "Loopdy Link session fork is invalid",
        strict_version=False,
    )
    if value.get("checkpointRole") not in {"user", "assistant"}:
        raise ValueError("Loopdy Link session fork is invalid")
    user_turn = _positive(value.get("userTurn"), "userTurn")
    if user_turn > 1_000_000:
        raise ValueError("Loopdy Link session fork turn is invalid")
    return SessionForkRequest(
        request_id=_opaque(value.get("requestId"), "requestId", 16, 128),
        source_session_id=_session_coordinate(
            value.get("sourceSessionId"), "sourceSessionId"
        ),
        fork_session_id=_session_coordinate(
            value.get("forkSessionId"), "forkSessionId"
        ),
        agent_id=_opaque(value.get("agentId"), "agentId", 1, 96),
        actor_id=_opaque(value.get("actorId"), "actorId", 1, 96),
        actor_name=_label(value.get("actorName"), "actorName", 80),
        device_name=_label(value.get("deviceName"), "deviceName", 96),
        user_turn=user_turn,
        checkpoint_role=str(value["checkpointRole"]),
        checkpoint_digest=_b64url(
            value.get("checkpointDigest"), "checkpointDigest", 32
        ),
        title=_activity_label(value.get("title"), "title", 240),
        sent_at=_positive(value.get("sentAt"), "sentAt"),
    )


def parse_command_catalog_request(value: dict[str, Any]) -> CommandCatalogRequest:
    expected = {
        "version",
        "type",
        "requestId",
        "sessionId",
        "agentId",
        "sentAt",
    }
    _validate_envelope(
        value, expected, "commands.catalog.request", "Loopdy Link command catalog request is invalid",
        strict_version=False,
    )
    return CommandCatalogRequest(
        request_id=_opaque(value.get("requestId"), "requestId", 16, 128),
        session_id=_session_coordinate(value.get("sessionId")),
        agent_id=_opaque(value.get("agentId"), "agentId", 1, 96),
        sent_at=_positive(value.get("sentAt"), "sentAt"),
    )


def command_catalog_payload(
    *,
    request: CommandCatalogRequest,
    commands: list[dict[str, Any]],
    sent_at: int,
) -> dict[str, Any]:
    if not isinstance(commands, list) or len(commands) > 1_000:
        raise ValueError("Loopdy Link command catalog is invalid")
    rows: list[dict[str, Any]] = []
    seen: set[str] = set()
    for command in commands:
        if not isinstance(command, dict):
            raise ValueError("Loopdy Link command is invalid")
        expected = {
            "name",
            "description",
            "category",
            "argsHint",
            "aliases",
            "argumentMode",
            "source",
            "requiresArguments",
        }
        if set(command) != expected:
            raise ValueError("Loopdy Link command is invalid")
        name = _command_name(command.get("name"), "name")
        if name in seen:
            raise ValueError("Loopdy Link command names must be unique")
        seen.add(name)
        aliases = command.get("aliases")
        if not isinstance(aliases, list) or len(aliases) > 32:
            raise ValueError("Loopdy Link command aliases are invalid")
        alias_rows = [_command_name(alias, "alias") for alias in aliases]
        if len(set(alias_rows)) != len(alias_rows):
            raise ValueError("Loopdy Link command aliases must be unique")
        argument_mode = command.get("argumentMode")
        source = command.get("source")
        requires_arguments = command.get("requiresArguments")
        if argument_mode not in {"none", "text", "options", "mixed"}:
            raise ValueError("Loopdy Link command argument mode is invalid")
        if source not in {"core", "plugin", "skill", "user"}:
            raise ValueError("Loopdy Link command source is invalid")
        if not isinstance(requires_arguments, bool):
            raise ValueError("Loopdy Link command requirement is invalid")
        rows.append(
            {
                "name": name,
                "description": _activity_label(
                    command.get("description"), "description", 240
                ),
                "category": _activity_label(
                    command.get("category"), "category", 80
                ),
                "argsHint": _command_args_hint(command.get("argsHint")),
                "aliases": alias_rows,
                "argumentMode": argument_mode,
                "source": source,
                "requiresArguments": requires_arguments,
            }
        )
    payload = {
        "version": 1,
        "type": "commands.catalog",
        "requestId": request.request_id,
        "sessionId": request.session_id,
        "agentId": request.agent_id,
        "commands": rows,
        "sentAt": _positive(sent_at, "sentAt"),
    }
    if len(json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")) > 240_000:
        raise ValueError("Loopdy Link command catalog is too large")
    return payload


def verified_fork_prefix(
    history: list[dict[str, Any]], request: SessionForkRequest
) -> list[dict[str, Any]]:
    if not isinstance(history, list) or not history or len(history) > 1_000_000:
        raise ValueError("Loopdy Link session history is invalid")
    user_turn = 0
    user_index: int | None = None
    for index, message in enumerate(history):
        if not isinstance(message, dict):
            raise ValueError("Loopdy Link session history is invalid")
        if message.get("role") == "user":
            user_turn += 1
            if user_turn == request.user_turn:
                user_index = index
                break
    if user_index is None:
        raise ValueError("Loopdy Link fork checkpoint is stale")

    checkpoint_index = user_index
    if request.checkpoint_role == "assistant":
        checkpoint_index = -1
        for index in range(user_index + 1, len(history)):
            message = history[index]
            if message.get("role") == "user":
                break
            if message.get("role") == "assistant" and isinstance(
                message.get("content"), str
            ):
                checkpoint_index = index
        if checkpoint_index < 0:
            raise ValueError("Loopdy Link fork checkpoint is stale")

    content = history[checkpoint_index].get("content")
    if not isinstance(content, str):
        raise ValueError("Loopdy Link fork checkpoint is stale")
    actual = base64.urlsafe_b64encode(
        hashlib.sha256(content.encode("utf-8")).digest()
    ).decode("ascii").rstrip("=")
    if not hmac.compare_digest(actual, request.checkpoint_digest):
        raise ValueError("Loopdy Link fork checkpoint changed")
    return list(history[: checkpoint_index + 1])


def session_fork_result(
    *,
    request: SessionForkRequest,
    status: str,
    title: str,
    message: str,
    sent_at: int,
) -> dict[str, Any]:
    if status not in {"completed", "failed", "conflict"}:
        raise ValueError("Loopdy Link session fork result is invalid")
    return {
        "version": 1,
        "type": "session.fork.result",
        "requestId": request.request_id,
        "sourceSessionId": request.source_session_id,
        "forkSessionId": request.fork_session_id,
        "status": status,
        "title": _activity_label(title, "title", 240),
        "message": _activity_label(message, "message", 2_000),
        "sentAt": _positive(sent_at, "sentAt"),
    }


def model_picker_payload(
    *,
    picker_id: str,
    session_id: str,
    current_model: str,
    current_provider: str,
    providers: list[dict[str, Any]],
    sent_at: int,
) -> dict[str, Any]:
    if not isinstance(providers, list) or not 1 <= len(providers) <= 32:
        raise ValueError("Loopdy Link model provider count is invalid")
    rows: list[dict[str, Any]] = []
    total_models = 0
    for provider in providers:
        if not isinstance(provider, dict):
            raise ValueError("Loopdy Link model provider is invalid")
        models = provider.get("models")
        if not isinstance(models, list) or not 1 <= len(models) <= 50:
            raise ValueError("Loopdy Link model count is invalid")
        model_ids = [
            _model_picker_identifier(model, "model", 1, 256)
            for model in models
        ]
        if len(set(model_ids)) != len(model_ids):
            raise ValueError("Loopdy Link model identifiers must be unique")
        total_models += len(model_ids)
        if total_models > 800:
            raise ValueError("Loopdy Link total model count is invalid")
        rows.append(
            {
                "id": _picker_identifier(provider.get("slug"), "provider", 1, 128),
                "name": _activity_label(
                    str(provider.get("name") or provider.get("slug") or ""),
                    "providerName",
                    80,
                ),
                "isCurrent": provider.get("is_current") is True,
                "isCustom": provider.get("is_user_defined") is True,
                "models": model_ids,
            }
        )
    value: dict[str, Any] = {
        "version": 1,
        "type": "picker.model",
        "pickerId": _opaque(picker_id, "pickerId", 16, 128),
        "sessionId": _session_coordinate(session_id),
        "currentModel": _model_picker_identifier(
            current_model or "unknown", "currentModel", 1, 256
        ),
        "currentProvider": _picker_identifier(
            current_provider or "unknown", "currentProvider", 1, 128
        ),
        "providers": rows,
        "sentAt": _positive(sent_at, "sentAt"),
    }
    if len(json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode("utf-8")) > 180_000:
        raise ValueError("Loopdy Link model picker is too large")
    return value


def choice_picker_payload(
    *,
    picker_id: str,
    session_id: str,
    title: str,
    choices: list[dict[str, Any]],
    sent_at: int,
) -> dict[str, Any]:
    if not isinstance(choices, list) or not 1 <= len(choices) <= 16:
        raise ValueError("Loopdy Link choice count is invalid")
    rows: list[dict[str, Any]] = []
    seen: set[str] = set()
    for choice in choices:
        if not isinstance(choice, dict):
            raise ValueError("Loopdy Link choice is invalid")
        value = _picker_identifier(choice.get("value"), "choiceValue", 1, 64)
        if value in seen:
            raise ValueError("Loopdy Link choice values must be unique")
        seen.add(value)
        rows.append(
            {
                "value": value,
                "label": _activity_label(
                    str(choice.get("label") or value), "choiceLabel", 96
                ),
                "isCurrent": choice.get("is_current") is True,
            }
        )
    return {
        "version": 1,
        "type": "picker.choice",
        "pickerId": _opaque(picker_id, "pickerId", 16, 128),
        "sessionId": _session_coordinate(session_id),
        "kind": "reasoning",
        "title": _picker_title(title, "title", 240),
        "choices": rows,
        "sentAt": _positive(sent_at, "sentAt"),
    }


def picker_result(
    *,
    picker_id: str,
    session_id: str,
    kind: str,
    status: str,
    message: str,
    sent_at: int,
) -> dict[str, Any]:
    if kind not in {"model", "reasoning"} or status not in {
        "completed",
        "failed",
        "expired",
    }:
        raise ValueError("Loopdy Link picker result is invalid")
    return {
        "version": 1,
        "type": "picker.result",
        "pickerId": _opaque(picker_id, "pickerId", 16, 128),
        "sessionId": _session_coordinate(session_id),
        "kind": kind,
        "status": status,
        "message": _picker_result_message(message, "message", 2_000),
        "sentAt": _positive(sent_at, "sentAt"),
    }


def _picker_title(value: Any, field: str, maximum: int) -> str:
    """Project Hermes' Markdown command title into native picker text.

    Hermes' interactive reasoning title is formatted for text surfaces (for
    example ``**Effort:** `medium` `` and line breaks). Loopdy renders this
    title as native UI, so remove those lightweight delimiters, normalize
    whitespace, and retain the same printable-label validation.
    """
    if not isinstance(value, str):
        raise ValueError(f"Loopdy Link {field} is invalid")
    plain = re.sub(r"[*_`~]", "", value)
    return _activity_label(" ".join(plain.split()), field, maximum)


def _picker_result_message(value: Any, field: str, maximum: int) -> str:
    """Project Hermes' text response into the native picker's single-line status."""
    if not isinstance(value, str):
        raise ValueError(f"Loopdy Link {field} is invalid")
    return _activity_label(" ".join(value.split()), field, maximum)


def _model_picker_identifier(value: Any, field: str, minimum: int, maximum: int) -> str:
    """Validate an opaque model name, including named presets with spaces."""
    if (
        not isinstance(value, str)
        or not minimum <= len(value) <= maximum
        or value != value.strip()
        or not value.isprintable()
    ):
        raise ValueError(f"Loopdy Link {field} is invalid")
    return value


def _command_name(value: Any, field: str) -> str:
    if (
        not isinstance(value, str)
        or not 1 <= len(value) <= 96
        or value.startswith("/")
        or any(
            not (character.islower() or character.isdigit() or character in "_-")
            for character in value
        )
    ):
        raise ValueError(f"Loopdy Link command {field} is invalid")
    return value


def _command_args_hint(value: Any) -> str:
    if value == "":
        return ""
    return _activity_label(value, "argsHint", 240)


def _personality_name(value: Any, *, allows_neutral: bool) -> str:
    if not isinstance(value, str):
        raise ValueError("Loopdy Link personality name is invalid")
    name = value.strip().lower()
    if allows_neutral and name in {"", "none", "default", "neutral"}:
        return ""
    if (
        not 1 <= len(name) <= 64
        or name in {"none", "default", "neutral"}
        or any(
            not (character.islower() or character.isdigit() or character in "_-")
            for character in name
        )
    ):
        raise ValueError("Loopdy Link personality name is invalid")
    return name


def _personality_definition(value: Any, *, response: bool = False) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError("Loopdy Link personality definition is invalid")
    required = {"name", "description", "systemPrompt", "tone", "style"}
    optional = {"originalName"}
    if response:
        required |= {"builtIn", "customized"}
        optional = set()
    if not required.issubset(value) or not set(value).issubset(required | optional):
        raise ValueError("Loopdy Link personality definition is invalid")
    description = _personality_line(value.get("description"), "description", 240)
    tone = _personality_line(value.get("tone"), "tone", 240)
    style = _personality_line(value.get("style"), "style", 240)
    prompt = value.get("systemPrompt")
    if (
        not isinstance(prompt, str)
        or not prompt.strip()
        or len(prompt) > 20_000
        or "\x00" in prompt
    ):
        raise ValueError("Loopdy Link personality systemPrompt is invalid")
    result: dict[str, Any] = {
        "name": _personality_name(value.get("name"), allows_neutral=False),
        "description": description,
        "systemPrompt": prompt.strip(),
        "tone": tone,
        "style": style,
    }
    if response:
        if not isinstance(value.get("builtIn"), bool) or not isinstance(
            value.get("customized"), bool
        ):
            raise ValueError("Loopdy Link personality source is invalid")
        result["builtIn"] = value["builtIn"]
        result["customized"] = value["customized"]
    elif "originalName" in value:
        result["originalName"] = _personality_name(
            value.get("originalName"), allows_neutral=False
        )
    return result


def _personality_line(value: Any, field: str, maximum: int) -> str:
    if (
        not isinstance(value, str)
        or len(value) > maximum
        or value != value.strip()
        or (value and not value.isprintable())
    ):
        raise ValueError(f"Loopdy Link personality {field} is invalid")
    return value
