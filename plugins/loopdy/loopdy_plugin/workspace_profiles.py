"""Agent profiles, assets, defaults and voice settings over Hermes-owned APIs."""

from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import inspect
from pathlib import Path
import re
from typing import Any
from .workspace_common import (
    WorkspaceConflictError,
    WorkspaceControlError,
    _HermesMethodUnavailable,
    _agent_id,
    _agent_id_from_name,
    _agent_payload_id,
    _coordinate,
    _display_name,
    _empty_payload,
    _identifier,
    _object,
    _optional_object,
    _text,
    _utf8_prefix,
)


class _ProfileCatalogUnavailable(WorkspaceControlError):
    """Only the exact missing profile-list import at the existing boundary."""

_PROFILE_CAPABILITY_MESSAGE = (
    "This Hermes gateway cannot list agent profiles. "
    "Update Hermes, restart the gateway, then reconnect Loopdy."
)

_REASONING_VALUES = frozenset(
    {"", "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"}
)


def _soul_digest(content: str) -> str:
    return base64.urlsafe_b64encode(
        hashlib.sha256(content.encode("utf-8")).digest()
    ).decode("ascii").rstrip("=")


def _soul_digest_coordinate(value: Any) -> str:
    digest = _coordinate(value, 43)
    if len(digest) != 43 or not re.fullmatch(r"[A-Za-z0-9_-]{43}", digest):
        raise WorkspaceControlError("SOUL digest is invalid")
    return digest


def _profile_ui_display_name(path: Any) -> str:
    """Read the user-facing name from Hermes profile metadata locally."""
    try:
        import yaml

        document = yaml.safe_load((path / "profile.yaml").read_text(encoding="utf-8"))
        if not isinstance(document, dict):
            return ""
        ui_meta = document.get("ui_meta")
        if not isinstance(ui_meta, dict):
            return ""
        return _text(ui_meta.get("displayName"), 80, allow_empty=True)
    except Exception:
        return ""


def _profile_has_avatar(path: Any) -> bool:
    try:
        from pathlib import Path

        assets = Path(path) / "assets"
        return any((assets / f"avatar.{ext}").is_file() for ext in ("png", "jpg", "webp"))
    except Exception:
        return False


def _agent_draft(payload: dict[str, Any]) -> dict[str, Any]:
    values = _object(payload, "workspace payload")
    if set(values) != {"agent"}:
        raise WorkspaceControlError("Agent payload is invalid")
    agent = _object(values.get("agent"), "agent")
    allowed = {"name", "role", "summary", "instructions", "isDefault", "avatar"}
    if set(agent) - allowed or not {"name", "role", "summary", "instructions"}.issubset(agent):
        raise WorkspaceControlError("Agent payload is invalid")
    draft = {
        "name": _text(agent.get("name"), 80),
        "role": _text(agent.get("role"), 160),
        "summary": _text(agent.get("summary"), 4_096),
        "instructions": _text(agent.get("instructions"), 256_000),
    }
    if "avatar" in agent:
        draft["avatar"] = _agent_avatar_payload(agent.get("avatar"))
    return draft


def _agent_avatar_payload(value: Any) -> dict[str, Any]:
    avatar = _object(value, "agent avatar")
    if set(avatar) != {"mimeType", "byteCount", "sha256", "data"}:
        raise WorkspaceControlError("Agent avatar payload is invalid")
    mime_type = avatar.get("mimeType")
    if mime_type not in {"image/png", "image/jpeg", "image/webp"}:
        raise WorkspaceControlError("Agent avatar payload is invalid")
    byte_count = avatar.get("byteCount")
    if not isinstance(byte_count, int) or isinstance(byte_count, bool) or byte_count <= 0:
        raise WorkspaceControlError("Agent avatar payload is invalid")
    sha256 = _text(avatar.get("sha256"), 128)
    if len(sha256) < 16:
        raise WorkspaceControlError("Agent avatar payload is invalid")
    data = _text(avatar.get("data"), 2_800_000)
    if not data.startswith(f"data:{mime_type};base64,"):
        raise WorkspaceControlError("Agent avatar payload is invalid")
    return {
        "mimeType": mime_type,
        "byteCount": byte_count,
        "sha256": sha256,
        "data": data,
    }


def _agent_avatar_projection(value: dict[str, Any]) -> dict[str, Any]:
    import base64
    import hashlib

    mime_type = value.get("mime")
    data = value.get("data")
    byte_count = value.get("size")
    if (
        mime_type not in {"image/png", "image/jpeg", "image/webp"}
        or not isinstance(data, str)
        or not data.startswith(f"data:{mime_type};base64,")
        or not isinstance(byte_count, int)
        or isinstance(byte_count, bool)
    ):
        raise WorkspaceControlError("Hermes returned an invalid agent avatar")
    try:
        blob = base64.b64decode(data.split(",", 1)[1], validate=True)
    except (ValueError, TypeError) as exc:
        raise WorkspaceControlError("Hermes returned an invalid agent avatar") from exc
    if len(blob) != byte_count:
        raise WorkspaceControlError("Hermes returned an invalid agent avatar")
    projected = {
        "mimeType": mime_type,
        "byteCount": byte_count,
        "sha256": base64.urlsafe_b64encode(hashlib.sha256(blob).digest()).decode().rstrip("="),
        "data": data,
    }
    return _agent_avatar_payload(projected)


def _model_identifier(value: Any, maximum: int) -> str:
    """Validate a model label without treating spaces as unsafe syntax.

    Hermes supports named model presets (for example, "Frontier Tuned").
    These are still opaque data: whitespace is valid, while control
    characters and leading/trailing whitespace are not.
    """
    candidate = _text(value, maximum, allow_empty=True).strip()
    if not candidate:
        return ""
    if candidate != str(value).strip() or not candidate.isprintable():
        raise WorkspaceControlError("Runtime model identifier is invalid")
    return candidate


def _reasoning(value: Any) -> str:
    candidate = _identifier(value, 32)
    if candidate not in _REASONING_VALUES:
        raise WorkspaceControlError("Reasoning effort is invalid")
    return candidate


def _selection(provider: Any, model: Any, reasoning: Any) -> dict[str, str]:
    return {
        "providerId": _identifier(provider, 128),
        "modelId": _model_identifier(model, 256),
        "reasoningEffort": _reasoning(reasoning),
    }


def _defaults(value: Any) -> dict[str, dict[str, str]]:
    defaults = _object(value, "agent defaults")
    expected = {"mainChats", "subagents", "scheduledTasks"}
    if set(defaults) != expected:
        raise WorkspaceControlError("Agent defaults are invalid")
    projected: dict[str, dict[str, str]] = {}
    for scope in sorted(expected):
        selection = _object(defaults.get(scope), "runtime selection")
        if set(selection) != {"providerId", "modelId", "reasoningEffort"}:
            raise WorkspaceControlError("Runtime selection is invalid")
        projected[scope] = _selection(
            selection.get("providerId"),
            selection.get("modelId"),
            selection.get("reasoningEffort"),
        )
    return projected


def _provider_projection(value: Any) -> list[dict[str, Any]]:
    options = _object(value, "model options")
    rows = options.get("providers")
    if not isinstance(rows, list) or len(rows) > 64:
        raise WorkspaceControlError("Model providers are invalid")
    current = _identifier(options.get("provider"), 128)
    providers = []
    for row in rows:
        source = _object(row, "model provider")
        provider_id = _identifier(source.get("slug", source.get("id")), 128)
        if not provider_id:
            raise WorkspaceControlError("Model provider is invalid")
        name = _text(source.get("name", source.get("label", provider_id)), 80)
        models = source.get("models")
        if not isinstance(models, list) or len(models) > 800:
            raise WorkspaceControlError("Provider model catalog is invalid")
        # Current Hermes intentionally includes canonical providers that are
        # not configured for this profile as empty rows. They are catalog
        # metadata, not selectable picker sections.
        if not models:
            continue
        projected_models = [_model_identifier(model, 256) for model in models]
        if any(not model for model in projected_models) or len(set(projected_models)) != len(projected_models):
            raise WorkspaceControlError("Provider model catalog is invalid")
        providers.append(
            {
                "id": provider_id,
                "name": name,
                "isCurrent": bool(source.get("is_current", provider_id == current)),
                "isCustom": bool(source.get("is_user_defined", False)),
                "models": projected_models,
            }
        )
    return providers


class ProfileControls:
    async def agents_list(self, payload: dict[str, Any]) -> dict[str, Any]:
        _empty_payload(payload)
        self._agent_catalog_compatibility = "unknown"
        try:
            records = await self._profile_records()
        except _ProfileCatalogUnavailable:
            self._agent_catalog_compatibility = "incompatible"
            raise
        if not isinstance(records, list) or len(records) > 128:
            raise WorkspaceControlError("Hermes returned an invalid agent catalog")
        agents = []
        for record in records:
            if not isinstance(record, dict):
                raise WorkspaceControlError("Hermes returned an invalid agent catalog")
            agent_id = _agent_id(record.get("id"))
            display_name = _text(
                record.get("ui_display_name") or record.get("display_name"),
                80,
                allow_empty=True,
            )
            description = _text(record.get("description"), 4_096, allow_empty=True)
            role = _utf8_prefix(description, 160) or "Hermes agent"
            soul = await self._profile_soul(agent_id)
            agent = {
                "id": agent_id,
                "name": display_name or _display_name(agent_id),
                "role": role,
                "summary": description or "Hermes agent",
                "instructions": _text(soul, 256_000, allow_empty=True),
                "isDefault": bool(record.get("is_default")),
                "hasAvatar": record.get("has_avatar") is True,
            }
            agents.append(agent)
        self._agent_catalog_compatibility = "compatible"
        return {"agents": agents}

    async def agents_create(self, payload: dict[str, Any]) -> dict[str, Any]:
        draft = _agent_draft(payload)
        agent_id = _agent_id_from_name(draft["name"])
        await self._create_profile(
            agent_id=agent_id,
            display_name=draft["name"],
            description=draft["summary"],
            instructions=draft["instructions"],
        )
        if "avatar" in draft:
            await self._set_profile_avatar(agent_id, draft["avatar"])
        canonical_avatar = await self._profile_avatar(agent_id)
        return {
            "agent": {
                "id": agent_id,
                **draft,
                "isDefault": agent_id == "default",
                "hasAvatar": canonical_avatar.get("found") is True,
            }
        }

    async def agents_update(self, payload: dict[str, Any]) -> dict[str, Any]:
        values = _object(payload, "workspace payload")
        if not {"agentId", "agent"}.issubset(values) or set(values) - {
            "agentId",
            "agent",
            "soulUpdate",
        }:
            raise WorkspaceControlError("Agent update payload is invalid")
        agent_id = _agent_id(values.get("agentId"))
        draft = _agent_draft({"agent": values.get("agent")})
        current_instructions = await self._profile_soul(agent_id)
        instructions: str | None = None
        expected_instructions_sha256: str | None = None
        if "soulUpdate" in values:
            soul_update = _object(values.get("soulUpdate"), "SOUL update")
            if set(soul_update) != {
                "confirmed",
                "expectedSha256",
                "instructions",
            } or soul_update.get("confirmed") is not True:
                raise WorkspaceControlError("SOUL update is not explicitly confirmed")
            expected_instructions_sha256 = _soul_digest_coordinate(
                soul_update.get("expectedSha256")
            )
            if not hmac.compare_digest(
                expected_instructions_sha256,
                _soul_digest(current_instructions),
            ):
                raise WorkspaceConflictError("SOUL changed before the update was confirmed")
            if not isinstance(soul_update.get("instructions"), str):
                raise WorkspaceControlError("SOUL update is invalid")
            instructions = _text(
                soul_update.get("instructions"),
                256_000,
                allow_empty=True,
            )
        await self._update_profile(
            agent_id=agent_id,
            display_name=draft["name"],
            description=draft["summary"],
            instructions=instructions,
            expected_instructions_sha256=expected_instructions_sha256,
        )
        if "avatar" in draft:
            await self._set_profile_avatar(agent_id, draft["avatar"])
        canonical_instructions = (
            instructions if instructions is not None else current_instructions
        )
        canonical_avatar = await self._profile_avatar(agent_id)
        return {
            "agent": {
                "id": agent_id,
                **draft,
                "instructions": canonical_instructions,
                "isDefault": agent_id == "default",
                "hasAvatar": canonical_avatar.get("found") is True,
            }
        }

    async def agents_avatar_get(self, payload: dict[str, Any]) -> dict[str, Any]:
        agent_id = _agent_payload_id(payload)
        avatar = await self._profile_avatar(agent_id)
        return {
            "agentId": agent_id,
            "avatar": (
                _agent_avatar_projection(avatar)
                if avatar.get("found") is True
                else None
            ),
        }

    async def agents_avatar_set(self, payload: dict[str, Any]) -> dict[str, Any]:
        values = _object(payload, "workspace payload")
        if set(values) != {"agentId", "avatar"}:
            raise WorkspaceControlError("Agent avatar payload is invalid")
        agent_id = _agent_id(values.get("agentId"))
        avatar_value = values.get("avatar")
        avatar = None if avatar_value is None else _agent_avatar_payload(avatar_value)
        await self._set_profile_avatar(agent_id, avatar)
        return {"agentId": agent_id, "hasAvatar": avatar is not None}

    async def agent_defaults_get(self, payload: dict[str, Any]) -> dict[str, Any]:
        agent_id = _agent_payload_id(payload)
        config, options = await asyncio.gather(
            self._profile_config(agent_id),
            self._model_options(agent_id),
        )
        config = _object(config, "Hermes config")
        raw_model = config.get("model")
        model = _optional_object(raw_model)
        if isinstance(raw_model, str):
            # Hermes' normalized config exposes the selected model as a
            # string; its provider is authoritative in get_model_options().
            model = {
                "provider": options.get("provider"),
                "default": raw_model,
            }
        agent = _optional_object(config.get("agent"))
        delegation = _optional_object(config.get("delegation"))
        cron = _optional_object(config.get("cron"))
        platforms = _optional_object(config.get("platforms"))
        loopdy = _optional_object(platforms.get("loopdy"))
        extra = _optional_object(loopdy.get("extra"))
        agent_defaults = _optional_object(extra.get("agent_defaults"))
        scheduled = _optional_object(agent_defaults.get("scheduled_tasks"))
        defaults = {
            "mainChats": _selection(
                model.get("provider"),
                model.get("default"),
                agent.get("reasoning_effort"),
            ),
            "subagents": _selection(
                delegation.get("provider"),
                delegation.get("model"),
                delegation.get("reasoning_effort"),
            ),
            "scheduledTasks": _selection(
                cron.get("model_provider", cron.get("provider")),
                cron.get("model"),
                scheduled.get("reasoning_effort"),
            ),
        }
        return {
            "agentId": agent_id,
            "defaults": defaults,
            "providers": _provider_projection(options),
        }

    async def agent_defaults_set(self, payload: dict[str, Any]) -> dict[str, Any]:
        values = _object(payload, "workspace payload")
        if set(values) != {"agentId", "defaults"}:
            raise WorkspaceControlError("Agent defaults payload is invalid")
        agent_id = _agent_id(values.get("agentId"))
        defaults = _defaults(values.get("defaults"))
        main = defaults["mainChats"]
        subagents = defaults["subagents"]
        scheduled = defaults["scheduledTasks"]
        config = {
            "model": {
                "provider": main["providerId"],
                "default": main["modelId"],
            },
            "agent": {"reasoning_effort": main["reasoningEffort"]},
            "delegation": {
                "provider": subagents["providerId"],
                "model": subagents["modelId"],
                "reasoning_effort": subagents["reasoningEffort"],
            },
            "cron": {
                "model_provider": scheduled["providerId"],
                "model": scheduled["modelId"],
            },
            "platforms": {
                "loopdy": {
                    "extra": {
                        "agent_defaults": {
                            "scheduled_tasks": {
                                "reasoning_effort": scheduled["reasoningEffort"]
                            }
                        }
                    }
                }
            },
        }
        await self._save_profile_config(agent_id, config)
        return {"agentId": agent_id, "defaults": defaults}

    async def voice_settings_get(self, payload: dict[str, Any]) -> dict[str, Any]:
        from .voice_settings import get_voice_settings

        return await get_voice_settings(self, payload)

    async def voice_settings_set(self, payload: dict[str, Any]) -> dict[str, Any]:
        from .voice_settings import set_voice_settings

        return await set_voice_settings(self, payload)

    async def _voice_settings_key_status(self, agent_id: str) -> dict[str, Any]:
        from .voice_settings import profile_key_status

        return await profile_key_status(agent_id)

    async def _profile_records(self) -> list[dict[str, Any]]:
        def load() -> list[dict[str, Any]]:
            try:
                from hermes_cli.profiles import list_profile_names
            except ImportError as exc:
                # Do not classify a missing module or a transitive import as
                # an incompatible profile API. Never return the exception text.
                if exc.name == "hermes_cli.profiles" and str(exc).startswith(
                    "cannot import name 'list_profile_names' from 'hermes_cli.profiles'"
                ):
                    raise _ProfileCatalogUnavailable(
                        _PROFILE_CAPABILITY_MESSAGE, code="hermes_capability_missing"
                    ) from None
                raise
            from hermes_cli.profiles import (
                get_profile_dir,
                profile_exists,
                read_profile_meta,
            )

            records = []
            for name in list_profile_names():
                if not profile_exists(name):
                    continue
                path = get_profile_dir(name)
                meta = read_profile_meta(path)
                records.append(
                    {
                        "id": name,
                        "display_name": meta.get("display_name", ""),
                        # Older Hermes profiles can persist the presentation
                        # name under ui_meta.displayName. Keep this local and
                        # project only the bounded display value.
                        "ui_display_name": _profile_ui_display_name(path),
                        "description": meta.get("description", ""),
                        "is_default": name == "default",
                        "has_avatar": _profile_has_avatar(path),
                    }
                )
            return records

        return await asyncio.to_thread(load)

    async def _profile_soul(self, agent_id: str) -> str:
        def load() -> str:
            from hermes_cli.profiles import get_profile_dir, profile_exists

            if not profile_exists(agent_id):
                raise WorkspaceControlError("The selected agent is unavailable")
            path = get_profile_dir(agent_id) / "SOUL.md"
            if not path.exists():
                return ""
            content = path.read_text(encoding="utf-8")
            return _text(content, 256_000, allow_empty=True)

        return await asyncio.to_thread(load)

    async def _create_profile(
        self,
        *,
        agent_id: str,
        display_name: str,
        description: str,
        instructions: str,
    ) -> None:
        def create() -> None:
            from hermes_cli import profiles
            from utils import atomic_write_text

            path = profiles.create_profile(
                name=agent_id,
                no_skills=False,
                description=description,
            )
            profiles.seed_profile_skills(path, quiet=True)
            if not profiles.check_alias_collision(agent_id):
                profiles.create_wrapper_script(agent_id)
            profiles.set_profile_display_name(agent_id, display_name)
            atomic_write_text(
                path / "SOUL.md",
                instructions,
                preserve_mode=True,
                create_mode=0o644,
            )

        await asyncio.to_thread(create)

    async def _update_profile(
        self,
        *,
        agent_id: str,
        display_name: str,
        description: str,
        instructions: str | None,
        expected_instructions_sha256: str | None,
    ) -> None:
        def update() -> None:
            from hermes_cli import profiles
            from utils import atomic_write_text

            if not profiles.profile_exists(agent_id):
                raise WorkspaceControlError("The selected agent is unavailable")
            path = profiles.get_profile_dir(agent_id)
            profiles.write_profile_meta(
                path,
                description=description,
                description_auto=False,
                display_name=display_name,
            )
            if instructions is not None:
                soul_path = path / "SOUL.md"
                current = (
                    soul_path.read_text(encoding="utf-8")
                    if soul_path.exists()
                    else ""
                )
                if (
                    expected_instructions_sha256 is None
                    or not hmac.compare_digest(
                        _soul_digest(current),
                        expected_instructions_sha256,
                    )
                ):
                    raise WorkspaceConflictError(
                        "SOUL changed before the update was committed"
                    )
                atomic_write_text(
                    soul_path,
                    instructions,
                    preserve_mode=True,
                    create_mode=0o644,
                )

        await asyncio.to_thread(update)

    async def _profile_avatar(self, agent_id: str) -> dict[str, Any]:
        return await self._profile_asset_request(
            "profiles.get_asset",
            {"name": agent_id, "asset": "avatar"},
        )

    async def _set_profile_avatar(self, agent_id: str, avatar: dict[str, Any] | None) -> None:
        params: dict[str, Any] = {"name": agent_id, "asset": "avatar"}
        if avatar is None:
            params["clear"] = True
        else:
            params["data"] = _agent_avatar_payload(avatar)["data"]
        result = await self._profile_asset_request("profiles.set_asset", params)
        if result.get("ok") is not True:
            raise WorkspaceControlError("Hermes could not update the agent avatar")

    async def _profile_asset_request(
        self,
        method: str,
        params: dict[str, Any],
    ) -> dict[str, Any]:
        return await self._hermes_request(
            method,
            params,
            unavailable_message="Hermes profile assets are unavailable",
            request_id="loopdy-profile-asset",
        )

    async def _profile_config(self, agent_id: str) -> dict[str, Any]:
        try:
            result = await self._hermes_request(
                "config.get",
                {"profile": agent_id, "key": "full"},
                unavailable_message="Hermes agent configuration is unavailable",
            )
            return _object(result.get("config"), "Hermes config")
        except (ImportError, _HermesMethodUnavailable):
            from hermes_cli.web_routers.config_env import get_config

            result = get_config(profile=agent_id)
            if inspect.isawaitable(result):
                result = await result
            return _object(result, "Hermes config")

    async def _model_options(self, agent_id: str) -> dict[str, Any]:
        try:
            return await self._hermes_request(
                "model.options",
                {"profile": agent_id, "explicit_only": True},
                unavailable_message="Hermes model options are unavailable",
            )
        except (ImportError, _HermesMethodUnavailable):
            from hermes_cli.web_routers.models import get_model_options

            parameters = inspect.signature(get_model_options).parameters.values()
            supports_explicit_filter = any(
                parameter.name == "explicit_only"
                or parameter.kind is inspect.Parameter.VAR_KEYWORD
                for parameter in parameters
            )
            keyword_arguments: dict[str, Any] = {"profile": agent_id}
            if supports_explicit_filter:
                keyword_arguments["explicit_only"] = True
            result = get_model_options(**keyword_arguments)
            if inspect.isawaitable(result):
                return await result
            return _object(result, "model options")

    async def _save_profile_config(
        self, agent_id: str, config: dict[str, Any]
    ) -> None:
        from hermes_cli.web_models import ConfigUpdate
        from hermes_cli.web_routers.config_env import update_config

        await update_config(
            ConfigUpdate(config=config, profile=agent_id),
            profile=agent_id,
        )
