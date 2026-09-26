"""Skills, capabilities and card-template workspace controls."""

from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import io
from pathlib import Path
import re
import stat
import zipfile
from typing import Any
from . import workspace_capabilities
from .workspace_common import (
    WorkspaceConflictError,
    WorkspaceControlError,
    _agent_id,
    _agent_payload_id,
    _coordinate,
    _nonnegative_integer,
    _object,
    _text,
)


_SKILL_NAME = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")

_SKILL_IDENTIFIER = re.compile(
    r"^[a-z0-9][a-z0-9._-]{0,63}(?::[a-z0-9][a-z0-9._-]{0,63})?$"
)

_SKILL_CATEGORY = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")

_SKILL_SUPPORT_ROOTS = frozenset({"assets", "references", "scripts", "templates"})


def card_template_projection(template: Any) -> dict[str, Any]:
    value = _object(template, "card template")
    keys = (
        "id",
        "version",
        "name",
        "summary",
        "author",
        "license",
        "minimum_card_version",
        "sha256",
    )
    if any(key not in value for key in keys):
        raise WorkspaceControlError("Card template projection is invalid")
    return {key: value[key] for key in keys}


def _card_template_agent_id(value: Any) -> str:
    try:
        return _agent_id(value)
    except WorkspaceControlError as error:
        raise ValueError("Card template agent ownership is invalid") from error


def _skill_name(value: Any) -> str:
    candidate = _text(value, 64)
    if not _SKILL_NAME.fullmatch(candidate):
        raise WorkspaceControlError("Skill name is invalid")
    return candidate


def _skill_identifier(value: Any) -> str:
    candidate = _text(value, 129)
    if not _SKILL_IDENTIFIER.fullmatch(candidate):
        raise WorkspaceControlError("Skill identifier is invalid")
    return candidate


def _skill_source_name(identifier: str) -> str:
    return identifier.rsplit(":", 1)[-1]


def _optional_skill_category(value: Any) -> str | None:
    if value is None:
        return None
    candidate = _text(value, 64)
    if not _SKILL_CATEGORY.fullmatch(candidate):
        raise WorkspaceControlError("Skill category is invalid")
    return candidate


def _sha256_coordinate(value: Any) -> str:
    candidate = _text(value, 64).lower()
    if not re.fullmatch(r"[0-9a-f]{64}", candidate):
        raise WorkspaceControlError("Skill revision is invalid")
    return candidate


def _skill_frontmatter_name(content: str) -> str:
    match = re.match(r"\A---\s*\n(.*?)\n---\s*(?:\n|\Z)", content, re.DOTALL)
    if not match:
        raise WorkspaceControlError("SKILL.md requires YAML frontmatter")
    try:
        import yaml

        frontmatter = yaml.safe_load(match.group(1))
    except Exception as exc:
        raise WorkspaceControlError("SKILL.md frontmatter is invalid") from exc
    if not isinstance(frontmatter, dict):
        raise WorkspaceControlError("SKILL.md frontmatter is invalid")
    return _skill_name(frontmatter.get("name"))


def _skill_content(value: Any, *, expected_name: str) -> str:
    content = _text(value, 100_000)
    actual_name = _skill_frontmatter_name(content)
    if actual_name != expected_name:
        raise WorkspaceControlError("SKILL.md name must match the selected skill")
    return content


def _decode_skill_zip(data: bytes) -> tuple[str, str, list[tuple[str, bytes]]]:
    if not data or len(data) > 1_500_000:
        raise WorkspaceControlError("Skill ZIP must be between 1 byte and 1.5 MB")
    try:
        archive = zipfile.ZipFile(io.BytesIO(data))
    except (zipfile.BadZipFile, OSError) as exc:
        raise WorkspaceControlError("Skill ZIP is invalid") from exc
    with archive:
        entries = [entry for entry in archive.infolist() if not entry.is_dir()]
        if not entries or len(entries) > 64:
            raise WorkspaceControlError("Skill ZIP has an invalid file count")
        normalized: list[tuple[zipfile.ZipInfo, tuple[str, ...]]] = []
        seen_paths: set[str] = set()
        expanded = 0
        for entry in entries:
            raw = entry.filename
            if (
                not raw
                or raw.startswith(("/", "\\"))
                or "\\" in raw
                or ":" in raw.split("/", 1)[0]
            ):
                raise WorkspaceControlError("Skill ZIP contains an unsafe path")
            parts = tuple(part for part in raw.split("/") if part not in {"", "."})
            if not parts or ".." in parts:
                raise WorkspaceControlError("Skill ZIP contains an unsafe path")
            path_key = "/".join(parts).casefold()
            if path_key in seen_paths:
                raise WorkspaceControlError("Skill ZIP contains duplicate paths")
            seen_paths.add(path_key)
            mode = entry.external_attr >> 16
            if stat.S_ISLNK(mode):
                raise WorkspaceControlError("Skill ZIP cannot contain symbolic links")
            if stat.S_IFMT(mode) not in {0, stat.S_IFREG} or entry.flag_bits & 1:
                raise WorkspaceControlError("Skill ZIP cannot contain special or encrypted files")
            if entry.file_size > 512_000:
                raise WorkspaceControlError("Skill ZIP contains an oversized file")
            expanded += entry.file_size
            if expanded > 4_000_000:
                raise WorkspaceControlError("Skill ZIP expands beyond 4 MB")
            normalized.append((entry, parts))

        skill_entries = [(entry, parts) for entry, parts in normalized if parts[-1].casefold() == "skill.md"]
        if len(skill_entries) != 1:
            raise WorkspaceControlError("Skill ZIP must contain exactly one SKILL.md")
        skill_entry, skill_parts = skill_entries[0]
        root_parts = skill_parts[:-1]
        for _, parts in normalized:
            if parts[: len(root_parts)] != root_parts:
                raise WorkspaceControlError("All skill files must share one archive folder")
        try:
            content = archive.read(skill_entry).decode("utf-8")
        except (UnicodeDecodeError, RuntimeError, zipfile.BadZipFile) as exc:
            raise WorkspaceControlError("SKILL.md must be UTF-8 text") from exc
        name = _skill_frontmatter_name(content)
        content = _skill_content(content, expected_name=name)
        supporting: list[tuple[str, bytes]] = []
        for entry, parts in normalized:
            relative_parts = parts[len(root_parts) :]
            if len(relative_parts) == 1 and relative_parts[0].casefold() == "skill.md":
                continue
            if not relative_parts or relative_parts[0] not in _SKILL_SUPPORT_ROOTS:
                raise WorkspaceControlError(
                    "Skill ZIP files must be under assets, references, scripts, or templates"
                )
            try:
                supporting.append(("/".join(relative_parts), archive.read(entry)))
            except (RuntimeError, zipfile.BadZipFile) as exc:
                raise WorkspaceControlError("Skill ZIP contains an unreadable file") from exc
        return name, content, supporting


class SkillControls:
    async def skills_tools_list(self, payload: dict[str, Any]) -> dict[str, Any]:
        agent_id = _agent_payload_id(payload)
        raw_skills, raw_plugins, raw_mcp = await asyncio.gather(
            self._skills_catalog(agent_id),
            self._plugins_catalog(agent_id),
            self._mcp_catalog(agent_id),
        )
        if not isinstance(raw_skills, list) or len(raw_skills) > 1_000:
            raise WorkspaceControlError("Hermes skill catalog is invalid")
        if not isinstance(raw_plugins, list) or len(raw_plugins) > 256:
            raise WorkspaceControlError("Hermes plugin catalog is invalid")
        servers = _object(raw_mcp, "Hermes MCP catalog").get("servers")
        if not isinstance(servers, list) or len(servers) > 256:
            raise WorkspaceControlError("Hermes MCP catalog is invalid")

        skills: list[dict[str, Any]] = []
        for value in raw_skills:
            source = _object(value, "Hermes skill")
            name = _text(source.get("name"), 160)
            skills.append(
                {
                    "id": name,
                    "name": name,
                    "description": _text(
                        source.get("description"), 4_096, allow_empty=True
                    ),
                    "category": _text(
                        source.get("category"), 120, allow_empty=True
                    ),
                    "enabled": source.get("enabled") is not False,
                }
            )

        plugins: list[dict[str, Any]] = []
        for value in raw_plugins:
            source = _object(value, "Hermes plugin")
            counts = [
                _nonnegative_integer(source.get(key, 0), maximum=100_000)
                for key in ("tools", "hooks", "middleware", "commands")
            ]
            plugin_id = _text(source.get("key", source.get("name")), 160)
            plugins.append(
                {
                    "id": plugin_id,
                    "name": _text(source.get("name", plugin_id), 160),
                    "kind": _text(source.get("kind"), 80, allow_empty=True),
                    "version": _text(source.get("version"), 80, allow_empty=True),
                    "description": _text(
                        source.get("description"), 4_096, allow_empty=True
                    ),
                    "enabled": source.get("enabled") is not False,
                    "capabilityCount": sum(counts),
                    "controlReason": _text(source.get("controlReason"), 1024, allow_empty=True),
                }
            )

        mcp_servers: list[dict[str, Any]] = []
        for value in servers:
            source = _object(value, "Hermes MCP server")
            name = _text(source.get("name"), 160)
            tools = source.get("tools")
            tool_count = None
            if isinstance(tools, list):
                if len(tools) > 10_000:
                    raise WorkspaceControlError("Hermes MCP tool catalog is invalid")
                tool_count = len(tools)
            elif tools is not None and not isinstance(tools, dict):
                raise WorkspaceControlError("Hermes MCP tool catalog is invalid")
            mcp_servers.append(
                {
                    "id": name,
                    "name": name,
                    "transport": _text(
                        source.get("transport", "unknown"), 32
                    ),
                    "enabled": source.get("enabled") is not False,
                    "toolCount": tool_count,
                }
            )
        tools = []
        tools_notice = ""
        try:
            raw_tools = await workspace_capabilities.toolsets(agent_id)
            for source in raw_tools:
                tools.append({
                    "id": _text(source.get("id"), 160),
                    "name": _text(source.get("name"), 160),
                    "description": _text(source.get("description"), 4096, allow_empty=True),
                    "platform": _text(source.get("platform"), 80),
                    "enabled": source["enabled"],
                    "toolCount": _nonnegative_integer(source.get("toolCount"), maximum=100_000),
                })
        except Exception:
            # An absent optional toolset API must not erase the older catalog.
            tools_notice = "Toolset configuration is unavailable on this Hermes host."
        return {
            "agentId": agent_id,
            "skills": skills,
            "plugins": plugins,
            "mcpServers": mcp_servers,
            "tools": tools,
            "management": workspace_capabilities.editor_capabilities(),
            "toolsNotice": tools_notice,
        }

    async def skills_tools_get(self, payload: dict[str, Any]) -> dict[str, Any]:
        values = _object(payload, "skill payload")
        if "capabilityKind" in values:
            return await self._capability_get(values)
        if set(values) != {"agentId", "skillId"}:
            raise WorkspaceControlError("Skill request is invalid")
        agent_id = _agent_id(values.get("agentId"))
        skill_id = _skill_identifier(values.get("skillId"))
        document = _object(
            await self._skill_content(agent_id, skill_id), "Hermes skill document"
        )
        content = _text(document.get("content"), 100_000)
        return {
            "agentId": agent_id,
            "skillId": skill_id,
            "content": content,
            "sha256": hashlib.sha256(content.encode("utf-8")).hexdigest(),
        }

    async def _capability_get(self, values: dict[str, Any]) -> dict[str, Any]:
        if set(values) != {"agentId", "capabilityKind", "capabilityId"}:
            raise WorkspaceControlError("Capability request is invalid")
        agent_id = _agent_id(values.get("agentId"))
        kind = values.get("capabilityKind")
        sections = {"skill": "skills", "plugin": "plugins", "mcpServer": "mcpServers", "toolset": "tools"}
        if not isinstance(kind, str) or kind not in sections:
            raise WorkspaceControlError("Capability type is invalid")
        item_id = _coordinate(values.get("capabilityId"), 160)
        catalog = await self.skills_tools_list({"agentId": agent_id})
        matches = [item for item in catalog[sections[kind]] if item["id"] == item_id]
        if len(matches) != 1:
            raise WorkspaceConflictError("This capability is no longer uniquely available in the selected profile. Refresh the catalog.")
        item = dict(matches[0])
        if kind == "plugin":
            item["identityAmbiguous"] = sum(row["name"] == item["name"] for row in catalog["plugins"]) != 1
        return {"agentId": agent_id, "control": workspace_capabilities.control(agent_id, kind, item)}

    async def _capability_set_enabled(self, values: dict[str, Any]) -> dict[str, Any]:
        if set(values) != {"agentId", "capabilityKind", "capabilityId", "enabled", "expectedRevision", "confirmed"}:
            raise WorkspaceControlError("Capability update is invalid")
        if values.get("confirmed") is not True or type(values.get("enabled")) is not bool:
            raise WorkspaceControlError("Confirm this capability change before applying it")
        expected = _sha256_coordinate(values.get("expectedRevision"))
        target = {key: values[key] for key in ("agentId", "capabilityKind", "capabilityId")}
        # Serialize this Link controller's mutations. Hermes owns config-file
        # locking; its public APIs do not offer cross-process compare-and-set.
        async with self._capability_update_lock:
            current = await self._capability_get(target)
            control = current["control"]
            if not control["canToggle"]:
                raise WorkspaceControlError(control["reason"], code="capability_locked")
            if not hmac.compare_digest(expected, control["revision"]):
                raise WorkspaceConflictError("Capability settings changed. Refresh and confirm again.")
            try:
                await workspace_capabilities.set_enabled(
                    current["agentId"], control["kind"], control["id"], values["enabled"]
                )
            except (ImportError, AttributeError) as exc:
                raise WorkspaceControlError(
                    "Update Hermes and the Loopdy host plugin to manage this capability.",
                    code="capability_unsupported",
                ) from exc
            except Exception as exc:
                # Never reflect host exceptions: they can contain config or paths.
                raise WorkspaceControlError(
                    "Hermes could not confirm this change. Refresh to read the saved state before retrying.",
                    code="capability_unconfirmed",
                ) from exc
            verified = await self._capability_get(target)
            if verified["control"]["enabled"] is not values["enabled"]:
                raise WorkspaceControlError(
                    "The saved state did not match the requested change. Refresh before retrying.",
                    code="capability_unconfirmed",
                )
            return verified

    async def skills_tools_create(self, payload: dict[str, Any]) -> dict[str, Any]:
        values = _object(payload, "skill payload")
        if set(values) not in (
            {"agentId", "name", "content"},
            {"agentId", "name", "content", "category"},
        ):
            raise WorkspaceControlError("Skill creation request is invalid")
        agent_id = _agent_id(values.get("agentId"))
        name = _skill_name(values.get("name"))
        content = _skill_content(values.get("content"), expected_name=name)
        category = _optional_skill_category(values.get("category"))
        await self._skill_create(agent_id, name, content, category)
        return await self.skills_tools_get({"agentId": agent_id, "skillId": name})

    async def skills_tools_update(self, payload: dict[str, Any]) -> dict[str, Any]:
        values = _object(payload, "skill payload")
        if "capabilityKind" in values:
            return await self._capability_set_enabled(values)
        if set(values) != {"agentId", "skillId", "content", "expectedSha256"}:
            raise WorkspaceControlError("Skill update request is invalid")
        agent_id = _agent_id(values.get("agentId"))
        skill_id = _skill_identifier(values.get("skillId"))
        content = _skill_content(
            values.get("content"), expected_name=_skill_source_name(skill_id)
        )
        expected = _sha256_coordinate(values.get("expectedSha256"))
        lock = self._skill_update_locks.setdefault((agent_id, skill_id), asyncio.Lock())
        async with lock:
            current = _object(
                await self._skill_content(agent_id, skill_id), "Hermes skill document"
            )
            current_content = _text(current.get("content"), 100_000)
            if not hmac.compare_digest(
                expected, hashlib.sha256(current_content.encode("utf-8")).hexdigest()
            ):
                raise WorkspaceConflictError("Skill changed before the update was saved")
            await self._skill_update(agent_id, skill_id, content)
            verified = await self.skills_tools_get({"agentId": agent_id, "skillId": skill_id})
            if verified["content"] != content:
                raise WorkspaceConflictError("Skill changed during the save. Reopen it before making further changes.")
            return verified

    async def skills_tools_import(self, payload: dict[str, Any]) -> dict[str, Any]:
        values = _object(payload, "skill import payload")
        if set(values) not in (
            {"agentId", "kind", "dataBase64"},
            {"agentId", "kind", "dataBase64", "category"},
        ):
            raise WorkspaceControlError("Skill import request is invalid")
        agent_id = _agent_id(values.get("agentId"))
        kind = values.get("kind")
        if kind not in {"skillMd", "zip"}:
            raise WorkspaceControlError("Skill import type is invalid")
        encoded = _text(values.get("dataBase64"), 2_100_000)
        try:
            data = base64.b64decode(encoded, validate=True)
        except (ValueError, TypeError) as exc:
            raise WorkspaceControlError("Skill import data is invalid") from exc
        category = _optional_skill_category(values.get("category"))
        if kind == "skillMd":
            if len(data) > 100_000:
                raise WorkspaceControlError("SKILL.md is too large")
            try:
                content = data.decode("utf-8")
            except UnicodeDecodeError as exc:
                raise WorkspaceControlError("SKILL.md must be UTF-8 text") from exc
            name = _skill_frontmatter_name(content)
            content = _skill_content(content, expected_name=name)
            await self._skill_create(agent_id, name, content, category)
        else:
            name, content, supporting_files = _decode_skill_zip(data)
            await self._skill_import_bundle(
                agent_id, name, content, category, supporting_files
            )
        return await self.skills_tools_get({"agentId": agent_id, "skillId": name})

    async def cards_templates_list(self, payload: dict[str, Any]) -> dict[str, Any]:
        values = _object(payload, "card template list payload")
        if set(values) != {"agentId"}:
            raise WorkspaceControlError("Card template list request is invalid")
        agent_id = _card_template_agent_id(values.get("agentId"))
        templates = self.service.store.list_card_templates(profile=agent_id)
        return {
            "agentId": agent_id,
            "templates": [card_template_projection(value) for value in templates],
        }

    async def cards_templates_install(self, payload: dict[str, Any]) -> dict[str, Any]:
        values = _object(payload, "card template install payload")
        if set(values) != {"agentId", "template"}:
            raise WorkspaceControlError("Card template install request is invalid")
        agent_id = _card_template_agent_id(values.get("agentId"))
        template = _object(values.get("template"), "card template")
        result = self.service.store.install_card_template(
            profile=agent_id,
            template=template,
        )
        return {
            "agentId": agent_id,
            "changed": result["changed"],
            "template": card_template_projection(result["template"]),
        }

    async def cards_templates_remove(self, payload: dict[str, Any]) -> dict[str, Any]:
        values = _object(payload, "card template removal payload")
        if set(values) != {"agentId", "templateId", "version", "sha256"}:
            raise WorkspaceControlError("Card template removal request is invalid")
        agent_id = _card_template_agent_id(values.get("agentId"))
        result = self.service.store.remove_card_template(
            profile=agent_id,
            template_id=values.get("templateId"),
            version=values.get("version"),
            sha256=values.get("sha256"),
        )
        return {"agentId": agent_id, **result}

    async def _skills_catalog(self, agent_id: str) -> list[dict[str, Any]]:
        from hermes_cli.web_routers.skills import get_skills

        return await get_skills(profile=agent_id)

    async def _skill_content(self, agent_id: str, skill_id: str) -> dict[str, Any]:
        from hermes_cli.web_routers.skills import get_skill_content

        try:
            return await get_skill_content(name=skill_id, profile=agent_id)
        except Exception as exc:
            raise WorkspaceControlError(
                "Skill could not be loaded. Refresh the catalog; if the problem persists, update Hermes and the Loopdy host plugin."
            ) from exc

    async def _skill_create(
        self, agent_id: str, name: str, content: str, category: str | None
    ) -> None:
        from hermes_cli.web_models import SkillCreate
        from hermes_cli.web_routers.skills import create_skill

        try:
            await create_skill(SkillCreate(
                name=name, content=content, category=category, profile=agent_id
            ))
        except Exception as exc:
            raise WorkspaceControlError(
                "Hermes rejected skill creation. Check the name, frontmatter and host security policy; an existing skill will not be overwritten."
            ) from exc

    async def _skill_update(self, agent_id: str, name: str, content: str) -> None:
        from hermes_cli.web_models import SkillContentUpdate
        from hermes_cli.web_routers.skills import update_skill_content

        try:
            await update_skill_content(SkillContentUpdate(
                name=name, content=content, profile=agent_id
            ))
        except Exception as exc:
            raise WorkspaceControlError(
                "Hermes rejected the skill update. Check the frontmatter and host security policy, then reopen the current skill before retrying."
            ) from exc

    async def _skill_import_bundle(
        self,
        agent_id: str,
        name: str,
        content: str,
        category: str | None,
        supporting_files: list[tuple[str, bytes]],
    ) -> None:
        from hermes_cli.web_routers.skills import _clear_skills_prompt_cache, _profile_scope
        from tools.skill_manager_tool import (
            _create_skill,
            _delete_skill,
            _find_skill,
            _security_scan_skill,
        )

        def _install() -> None:
            with _profile_scope(agent_id):
                result = _create_skill(name, content, category)
                if not result.get("success"):
                    raise WorkspaceControlError(
                        "Hermes rejected the skill bundle. Check its name, frontmatter and host security policy."
                    )
                try:
                    found = _find_skill(name)
                    if not found:
                        raise WorkspaceControlError("Created skill could not be resolved")
                    root = Path(found["path"]).resolve()
                    for relative, data in supporting_files:
                        destination = (root / relative).resolve()
                        if root not in destination.parents:
                            raise WorkspaceControlError("Skill archive path is invalid")
                        destination.parent.mkdir(parents=True, exist_ok=True)
                        with destination.open("xb") as handle:
                            handle.write(data)
                    scan_error = _security_scan_skill(root)
                    if scan_error:
                        raise WorkspaceControlError("Hermes security policy rejected the skill bundle; the new bundle was removed.")
                except Exception:
                    _delete_skill(name)
                    raise
            _clear_skills_prompt_cache()

        await asyncio.to_thread(_install)

    async def _plugins_catalog(self, agent_id: str) -> list[dict[str, Any]]:
        return await workspace_capabilities.plugins(agent_id)

    async def _mcp_catalog(self, agent_id: str) -> dict[str, Any]:
        from hermes_cli.web_routers.mcp import list_mcp_servers

        return await list_mcp_servers(profile=agent_id)
