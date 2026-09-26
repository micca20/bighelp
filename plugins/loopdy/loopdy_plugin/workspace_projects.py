"""Registered Projects and policy-gated Project Git workspace controls."""

from __future__ import annotations

import asyncio
from contextlib import contextmanager
import hashlib
import inspect
import json
import os
from pathlib import Path
import re
from typing import Any
from .project_git_validation import ProjectGitValidation
from .link_contracts import _workspace_json
from .workspace_git import WorkspaceGitError, WorkspaceGitService
from .workspace_capabilities import profile_scope
from .workspace_common import (
    WorkspaceControlError,
    _agent_id,
    _coordinate,
    _nonnegative_integer,
    _object,
    _optional_coordinate,
    _text,
)


_PROJECT_DIRECTORY_PAGE_LIMIT = 100

_PROJECT_DIRECTORY_OFFSET_LIMIT = 100_000

_PROJECT_DIRECTORY_HIDDEN = frozenset({
    ".git",
    ".hg",
    ".svn",
    ".cache",
    ".next",
    ".turbo",
    ".venv",
    "__pycache__",
    "build",
    "dist",
    "node_modules",
    "target",
    "venv",
})


@contextmanager
def _project_connection(agent_id: str, projects_db):
    """Select and restore the profile inside the existing worker, around DB close."""
    with profile_scope(agent_id, missing_error=WorkspaceControlError("The selected agent is unavailable")):
        with projects_db.connect_closing() as connection:
            yield connection


def _project_primary_path(project: dict[str, Any]) -> str:
    direct = project.get("primary_path")
    if isinstance(direct, str) and direct.strip():
        return _absolute_project_path(direct)
    folders = project.get("folders")
    if not isinstance(folders, list) or not folders:
        raise WorkspaceControlError("Project Git Project has no registered folder")
    primary = next(
        (
            row.get("path")
            for row in folders
            if isinstance(row, dict) and row.get("is_primary") is True
        ),
        None,
    )
    if primary is None and isinstance(folders[0], dict):
        primary = folders[0].get("path")
    return _absolute_project_path(primary)


def _session_workspace_identity(
    cwd: Any, catalog: dict[str, Any]
) -> tuple[str | None, str | None]:
    if not isinstance(cwd, str) or not cwd.strip():
        return None, None
    candidate = Path(cwd).expanduser()
    if not candidate.is_absolute():
        return None, None
    try:
        canonical_cwd = candidate.resolve(strict=False)
    except (OSError, RuntimeError, ValueError):
        return None, None
    rows = catalog.get("projects")
    if not isinstance(rows, list) or len(rows) > 256:
        raise WorkspaceControlError("Hermes project catalog is invalid")
    matches: dict[tuple[str, str], int] = {}
    for value in rows:
        project = _object(value, "Hermes project")
        if project.get("archived") is True:
            continue
        identity = (
            _coordinate(project.get("id"), 160),
            _text(project.get("name"), 160),
        )
        raw_paths = [project.get("primary_path")]
        folders = project.get("folders")
        if isinstance(folders, list):
            if len(folders) > 64:
                raise WorkspaceControlError("Hermes project catalog is invalid")
            raw_paths.extend(
                folder.get("path")
                for folder in folders
                if isinstance(folder, dict)
            )
        for raw_path in raw_paths:
            try:
                project_path = Path(_absolute_project_path(raw_path))
                canonical_cwd.relative_to(project_path)
            except (WorkspaceControlError, ValueError):
                continue
            depth = len(project_path.parts)
            matches[identity] = max(depth, matches.get(identity, 0))
    if not matches:
        return None, None
    deepest = max(matches.values())
    owners = [identity for identity, depth in matches.items() if depth == deepest]
    return owners[0] if len(owners) == 1 else (None, None)


def _absolute_project_path(value: Any) -> str:
    if not isinstance(value, str) or not value.strip():
        raise WorkspaceControlError("Project Git Project path is invalid")
    candidate = Path(value).expanduser()
    if not candidate.is_absolute() or ".." in candidate.parts:
        raise WorkspaceControlError("Project Git Project path is invalid")
    return str(candidate.resolve(strict=False))


def _same_project_path(left: Any, right: Any) -> bool:
    left_path = Path(_absolute_project_path(left))
    right_path = Path(_absolute_project_path(right))
    if left_path == right_path:
        return True
    try:
        return left_path.samefile(right_path)
    except OSError:
        return False

_git_values = ProjectGitValidation(WorkspaceControlError, 'Project Git', choice_label='operation')

_project_git_operation_input = _git_values.operation_input

_project_git_relative_path = _git_values.relative_path

_project_git_ref = _git_values.ref

_project_git_choice = _git_values.choice

_project_git_status_token = _git_values.status_token


def _project_git_policy(workspace_id: str, project_root: str) -> dict[str, Any]:
    default = {
        "visibility": "private",
        "operations": ["status"],
        "remotes": [],
        "branches": [],
        "mutations_enabled": False,
    }
    raw = os.getenv("LOOPDY_WORKSPACE_GIT_CONFIG", "").strip()
    if not raw:
        return default
    try:
        configured = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise WorkspaceControlError("Project Git host policy is invalid") from exc
    if not isinstance(configured, list) or len(configured) > 256:
        raise WorkspaceControlError("Project Git host policy is invalid")
    matches = [
        row
        for row in configured
        if isinstance(row, dict) and row.get("workspace_id") == workspace_id
    ]
    if len(matches) > 1:
        raise WorkspaceControlError("Project Git host policy is ambiguous")
    if not matches:
        return default
    selected = matches[0]
    configured_root = selected.get("root")
    if _absolute_project_path(configured_root) != project_root:
        return default
    operations = selected.get("operations")
    remotes = selected.get("remotes")
    branches = selected.get("branches")
    if (
        not isinstance(operations, list)
        or not isinstance(remotes, list)
        or not isinstance(branches, list)
    ):
        raise WorkspaceControlError("Project Git host policy is invalid")
    allowed = {"status", "stage", "commit", "fetch", "pull", "push"}
    operation_set = {str(item) for item in operations}
    if not operation_set or not operation_set <= allowed:
        raise WorkspaceControlError("Project Git host policy is invalid")
    visibility = selected.get("visibility", "private")
    if visibility not in {"private", "public"}:
        raise WorkspaceControlError("Project Git host policy is invalid")
    return {
        "visibility": visibility,
        "operations": sorted(operation_set | {"status"}),
        "remotes": [_project_git_ref(item, "remote") for item in remotes],
        "branches": [_project_git_ref(item, "branch") for item in branches],
        "mutations_enabled": selected.get("mutations_enabled") is True,
    }


def _project_git_wire(value: Any) -> Any:
    key_map = {
        "schema_version": "schemaVersion",
        "arbitrary_command": "arbitraryCommand",
        "workspace_id": "workspaceId",
        "mutations_enabled": "mutationsEnabled",
        "status_token": "statusToken",
        "original_path": "originalPath",
        "is_binary": "isBinary",
        "files_page": "filesPage",
        "conflicts_page": "conflictsPage",
        "next_offset": "nextOffset",
        "preview_content": "previewContent",
        "old_line": "oldLine",
        "new_line": "newLine",
        "confirmation_token": "confirmationToken",
        "operation_digest": "operationDigest",
        "expires_at": "expiresAt",
        "operation_id": "operationId",
        "commit_oid": "commitOid",
        "parent_oid": "parentOid",
        "tree_oid": "treeOid",
        "updated_refs": "updatedRefs",
        "rule_id": "ruleId",
    }
    if isinstance(value, list):
        return [_project_git_wire(item) for item in value]
    if isinstance(value, dict):
        projected: dict[str, Any] = {}
        for key, item in value.items():
            if not isinstance(key, str) or not re.fullmatch(r"[a-z][a-z0-9_]{0,63}", key):
                raise WorkspaceControlError("Project Git response is invalid")
            projected[key_map.get(key, key)] = _project_git_wire(item)
        return projected
    return _workspace_json(value, depth=1)


def _project_git_control_error(error: WorkspaceGitError) -> WorkspaceControlError:
    code_map = {
        "STATUS_STALE": ("status_changed", "conflict", "Project changes changed. Refresh and try again."),
        "CONFIRMATION_INVALID": ("confirmation_expired", "conflict", "Prepare this Git operation again."),
        "IDEMPOTENCY_CONFLICT": ("idempotency_conflict", "conflict", "This Git operation identity was already used."),
        "INVALID_REQUEST": ("invalid_request", "failed", "The Git request is invalid."),
        "INVALID_PATH": ("invalid_path", "failed", "The selected Project path is invalid."),
        "UNSUPPORTED_PATH_ENCODING": ("diff_unavailable", "failed", "This Project path cannot be displayed."),
        "WORKSPACE_NOT_ALLOWED": ("project_unavailable", "failed", "Project Git is unavailable for this Project."),
        "OPERATION_NOT_ALLOWED": ("operation_disabled", "failed", "This Git operation is disabled by the host."),
        "PROJECT_NOT_REPOSITORY": ("project_not_repository", "failed", "This Project is not a Git repository."),
        "GIT_UNAVAILABLE": ("git_unavailable", "failed", "Git is unavailable for this Project."),
        "GIT_TIMEOUT": ("git_timeout", "failed", "Git did not finish in time. Retry after refreshing."),
        "REMOTE_UNAVAILABLE": ("remote_unavailable", "failed", "The configured Git remote is unavailable."),
        "AUTHENTICATION_FAILED": ("authentication_failed", "failed", "Git authentication failed on the Hermes host."),
        "SECRET_SCAN_BLOCKED": ("sensitive_data_blocked", "failed", "The staged changes require review before committing."),
        "PUBLIC_REPO_SAFETY_BLOCK": ("sensitive_data_blocked", "failed", "The outgoing changes require review before continuing."),
        "BRANCH_MISMATCH": ("branch_mismatch", "failed", "The current branch is not enabled for this operation."),
        "UPSTREAM_REQUIRED": ("upstream_required", "failed", "This branch does not track the enabled upstream."),
        "NON_FAST_FORWARD": ("non_fast_forward", "failed", "The branch cannot be updated safely without review."),
        "WORKTREE_CONFLICTED": ("worktree_conflicted", "failed", "Resolve Project conflicts before continuing."),
        "WORKTREE_NOT_CLEAN": ("worktree_not_clean", "failed", "The Project must be clean before this operation."),
        "NOTHING_TO_STAGE": ("nothing_to_stage", "failed", "The selected files cannot be staged in their current state."),
        "NOTHING_TO_COMMIT": ("nothing_to_commit", "failed", "Stage changes before committing."),
        "NOTHING_TO_PULL": ("nothing_to_pull", "failed", "The Project is already up to date."),
        "NOTHING_TO_PUSH": ("nothing_to_push", "failed", "The upstream already has this branch."),
        "GIT_OUTCOME_UNKNOWN": ("outcome_unknown", "conflict", "The Git result is uncertain. Refresh before continuing."),
    }
    code, status, message = code_map.get(
        error.code,
        ("project_git_failed", "failed", "Hermes could not complete this Git operation."),
    )
    return WorkspaceControlError(message, code=code, status=status)


def _canonical_project_directory(value: Any) -> str:
    raw = _text(value, 4_096)
    candidate = Path(raw).expanduser()
    if not candidate.is_absolute() or ".." in candidate.parts:
        raise WorkspaceControlError("Workspace folder path is invalid")
    try:
        resolved = candidate.resolve(strict=True)
        if not resolved.is_dir() or not os.access(resolved, os.R_OK | os.X_OK):
            raise WorkspaceControlError("Workspace folder is not readable")
    except WorkspaceControlError:
        raise
    except (OSError, RuntimeError) as exc:
        raise WorkspaceControlError("Workspace folder is unavailable") from exc
    return str(resolved)


def _project_directory_prefix(value: Any) -> str:
    prefix = _text(value, 255, allow_empty=True)
    if prefix in {".", ".."} or "/" in prefix or "\\" in prefix:
        raise WorkspaceControlError("Workspace folder prefix is invalid")
    return prefix


def _project_directory_page(
    parent_path: str,
    prefix: str,
    offset: int,
    limit: int,
) -> dict[str, Any]:
    folded_prefix = prefix.casefold()
    folders: list[dict[str, str]] = []
    try:
        with os.scandir(parent_path) as entries:
            for entry in entries:
                if (
                    entry.name.startswith(".")
                    or entry.name in _PROJECT_DIRECTORY_HIDDEN
                    or not entry.name.casefold().startswith(folded_prefix)
                    or entry.is_symlink()
                    or not entry.is_dir(follow_symlinks=False)
                ):
                    continue
                folders.append({
                    "name": entry.name,
                    "path": str(Path(parent_path, entry.name)),
                })
    except (FileNotFoundError, NotADirectoryError, PermissionError, OSError) as exc:
        raise WorkspaceControlError("Workspace folder is not readable") from exc
    folders.sort(key=lambda item: (item["name"].casefold(), item["name"]))
    page = folders[offset : offset + limit]
    next_offset = offset + len(page)
    return {
        "parentPath": parent_path,
        "folders": page,
        "nextOffset": next_offset if next_offset < len(folders) else None,
    }


class ProjectControls:
    async def projects_list(self, payload: dict[str, Any]) -> dict[str, Any]:
        values = _object(payload, "workspace payload")
        if set(values) not in ({"agentId"}, {"agentId", "sessionId"}):
            raise WorkspaceControlError("Project list payload is invalid")
        agent_id = _agent_id(values.get("agentId"))
        session_id = _optional_coordinate(values.get("sessionId"), 128)
        projection = await self._project_projection(agent_id)
        if session_id is None:
            return projection

        getter = self.session_workspace_getter
        if not callable(getter):
            raise WorkspaceControlError("Workspace session anchoring is unavailable")
        session_root = getter(agent_id, session_id)
        if inspect.isawaitable(session_root):
            session_root = await session_root
        if session_root in (None, ""):
            projection["sessionWorkspaceId"] = None
            return projection

        canonical_root = _absolute_project_path(session_root)
        raw_catalog = _object(
            await self._projects_catalog(agent_id), "Hermes project catalog"
        )
        rows = raw_catalog.get("projects")
        if not isinstance(rows, list) or len(rows) > 256:
            raise WorkspaceControlError("Hermes project catalog is invalid")
        matches = [
            _coordinate(project.get("id"), 160)
            for project in rows
            if isinstance(project, dict)
            and project.get("archived") is not True
            and _project_primary_path(project) == canonical_root
        ]
        if len(matches) > 1:
            raise WorkspaceControlError("Workspace session anchoring is ambiguous")
        projection["sessionWorkspaceId"] = matches[0] if matches else None
        return projection

    async def projects_set_active(self, payload: dict[str, Any]) -> dict[str, Any]:
        values = _object(payload, "workspace payload")
        if set(values) not in (
            {"agentId", "workspaceId"},
            {"agentId", "workspaceId", "sessionId"},
        ):
            raise WorkspaceControlError("Workspace selection payload is invalid")
        agent_id = _agent_id(values.get("agentId"))
        workspace_id = _coordinate(values.get("workspaceId"), 160)
        session_id = _optional_coordinate(values.get("sessionId"), 128)
        catalog = await self._project_projection(agent_id)
        if not any(row["id"] == workspace_id for row in catalog["workspaces"]):
            raise WorkspaceControlError("Workspace is unavailable")
        if session_id is not None:
            setter = self.session_workspace_setter
            primary_path = await self._project_directory(agent_id, workspace_id)
            if not callable(setter) or not primary_path:
                raise WorkspaceControlError("Workspace session anchoring is unavailable")
            result = setter(agent_id, session_id, primary_path)
            if inspect.isawaitable(result):
                await result
        await self._set_active_project(agent_id, workspace_id)
        return await self._project_projection(agent_id)

    async def projects_create(self, payload: dict[str, Any]) -> dict[str, Any]:
        values = _object(payload, "workspace payload")
        if set(values) != {"agentId", "name", "folderPath"}:
            raise WorkspaceControlError("Workspace creation payload is invalid")
        agent_id = _agent_id(values.get("agentId"))
        name = _text(values.get("name"), 160)
        folder_path = _canonical_project_directory(values.get("folderPath"))
        await self._create_project(agent_id, name, folder_path)
        return await self._project_projection(agent_id)

    async def projects_archive(self, payload: dict[str, Any]) -> dict[str, Any]:
        values = _object(payload, "workspace payload")
        if set(values) != {"agentId", "workspaceId"}:
            raise WorkspaceControlError("Workspace archive payload is invalid")
        agent_id = _agent_id(values.get("agentId"))
        workspace_id = _coordinate(values.get("workspaceId"), 160)
        await self._archive_project(agent_id, workspace_id)
        return await self._project_projection(agent_id)

    async def projects_list_directory(self, payload: dict[str, Any]) -> dict[str, Any]:
        values = _object(payload, "workspace payload")
        if set(values) != {"agentId", "parentPath", "prefix", "offset", "limit"}:
            raise WorkspaceControlError("Workspace directory payload is invalid")
        _agent_id(values.get("agentId"))
        parent_path = _canonical_project_directory(values.get("parentPath"))
        prefix = _project_directory_prefix(values.get("prefix"))
        offset = _nonnegative_integer(
            values.get("offset"), maximum=_PROJECT_DIRECTORY_OFFSET_LIMIT
        )
        limit = _nonnegative_integer(
            values.get("limit"), maximum=_PROJECT_DIRECTORY_PAGE_LIMIT
        )
        if limit == 0:
            raise WorkspaceControlError("Workspace directory page is invalid")
        return await asyncio.to_thread(
            _project_directory_page,
            parent_path,
            prefix,
            offset,
            limit,
        )

    async def projects_git_capabilities(
        self, payload: dict[str, Any]
    ) -> dict[str, Any]:
        context = await self._project_git_context(
            payload, {"agentId", "sessionId", "workspaceId"}
        )
        try:
            raw = await asyncio.to_thread(context["service"].capabilities)
        except WorkspaceGitError as exc:
            raise _project_git_control_error(exc) from exc
        value = _object(raw, "Project Git capabilities")
        rows = value.get("workspaces")
        if not isinstance(rows, list):
            raise WorkspaceControlError("Project Git capability response is invalid")
        selected = [
            row
            for row in rows
            if isinstance(row, dict)
            and row.get("workspace_id") == context["workspace_id"]
        ]
        if len(selected) != 1:
            raise WorkspaceControlError("Project Git is unavailable for this Project")
        selected_operations = selected[0].get("operations")
        if not isinstance(selected_operations, list):
            raise WorkspaceControlError("Project Git capability response is invalid")
        enabled = set(selected_operations)
        mutations_enabled = selected[0].get("mutations_enabled") is True
        return _project_git_wire(
            {
                "schema_version": value.get("schema_version"),
                "capabilities": {
                    "status": "status" in enabled,
                    "stage": mutations_enabled and "stage" in enabled,
                    "commit": mutations_enabled and "commit" in enabled,
                    "push": mutations_enabled and "push" in enabled,
                    "fetch": mutations_enabled and "fetch" in enabled,
                    "pull": mutations_enabled and "pull" in enabled,
                    "arbitrary_command": False,
                },
                "workspaces": selected,
            }
        )

    async def projects_git_status(self, payload: dict[str, Any]) -> dict[str, Any]:
        context = await self._project_git_context(
            payload, {"agentId", "sessionId", "workspaceId"}
        )
        try:
            raw = await asyncio.to_thread(
                context["service"].status, context["workspace_id"]
            )
        except WorkspaceGitError as exc:
            raise _project_git_control_error(exc) from exc
        return _project_git_wire(_object(raw, "Project Git status"))

    async def projects_git_diff(self, payload: dict[str, Any]) -> dict[str, Any]:
        context = await self._project_git_context(
            payload,
            {
                "agentId",
                "sessionId",
                "workspaceId",
                "path",
                "side",
                "statusToken",
                "offset",
                "limit",
            },
        )
        path = _project_git_relative_path(context["values"].get("path"))
        side = _project_git_choice(
            context["values"].get("side"), {"staged", "worktree"}
        )
        status_token = _project_git_status_token(
            context["values"].get("statusToken")
        )
        offset = _nonnegative_integer(
            context["values"].get("offset"), maximum=100_000
        )
        limit = _nonnegative_integer(
            context["values"].get("limit"), maximum=500
        )
        if limit < 1:
            raise WorkspaceControlError("Project Git diff page is invalid")
        try:
            raw = await asyncio.to_thread(
                context["service"].diff,
                context["workspace_id"],
                path=path,
                side=side,
                expected_status_token=status_token,
                offset=offset,
                limit=limit,
            )
        except WorkspaceGitError as exc:
            raise _project_git_control_error(exc) from exc
        return _project_git_wire(_object(raw, "Project Git diff"))

    async def projects_git_prepare(self, payload: dict[str, Any]) -> dict[str, Any]:
        context = await self._project_git_context(
            payload,
            {
                "agentId",
                "sessionId",
                "workspaceId",
                "operation",
                "statusToken",
                "input",
            },
        )
        operation = _project_git_choice(
            context["values"].get("operation"),
            {"stage", "commit", "fetch", "pull", "push"},
        )
        input_ = _project_git_operation_input(
            operation, context["values"].get("input")
        )
        connection_id = self._project_git_connection_id()
        try:
            raw = await asyncio.to_thread(
                context["service"].prepare,
                workspace_id=context["workspace_id"],
                operation=operation,
                input_=input_,
                expected_status_token=_project_git_status_token(
                    context["values"].get("statusToken")
                ),
                connection_id=connection_id,
            )
        except WorkspaceGitError as exc:
            raise _project_git_control_error(exc) from exc
        return _project_git_wire(_object(raw, "Project Git preparation"))

    async def projects_git_execute(self, payload: dict[str, Any]) -> dict[str, Any]:
        context = await self._project_git_context(
            payload,
            {
                "agentId",
                "sessionId",
                "workspaceId",
                "operation",
                "statusToken",
                "input",
                "confirmationToken",
                "idempotencyKey",
            },
        )
        operation = _project_git_choice(
            context["values"].get("operation"),
            {"stage", "commit", "fetch", "pull", "push"},
        )
        input_ = _project_git_operation_input(
            operation, context["values"].get("input")
        )
        confirmation_token = _coordinate(
            context["values"].get("confirmationToken"), 200
        )
        idempotency_key = context["values"].get("idempotencyKey")
        if not isinstance(idempotency_key, str) or not re.fullmatch(
            r"[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}",
            idempotency_key,
        ):
            raise WorkspaceControlError("Project Git idempotency key is invalid")
        request = {
            "workspace_id": context["workspace_id"],
            "expected_status_token": _project_git_status_token(
                context["values"].get("statusToken")
            ),
            "confirmation_token": confirmation_token,
            "idempotency_key": idempotency_key,
            **input_,
        }
        try:
            raw = await asyncio.to_thread(
                context["service"].execute,
                operation,
                request,
                connection_id=self._project_git_connection_id(),
            )
        except WorkspaceGitError as exc:
            raise _project_git_control_error(exc) from exc
        return _project_git_wire(_object(raw, "Project Git execution"))

    async def _project_git_context(
        self,
        payload: dict[str, Any],
        expected_keys: set[str],
    ) -> dict[str, Any]:
        values = _object(payload, "Project Git payload")
        if set(values) != expected_keys:
            raise WorkspaceControlError("Project Git payload is invalid")
        agent_id = _agent_id(values.get("agentId"))
        session_id = _coordinate(values.get("sessionId"), 128)
        workspace_id = _coordinate(values.get("workspaceId"), 160)
        raw_catalog = _object(
            await self._projects_catalog(agent_id), "Hermes project catalog"
        )
        projects = raw_catalog.get("projects")
        if not isinstance(projects, list) or len(projects) > 256:
            raise WorkspaceControlError("Hermes project catalog is invalid")
        matches = [
            _object(row, "Hermes project")
            for row in projects
            if isinstance(row, dict)
            and row.get("id") == workspace_id
            and row.get("archived") is not True
        ]
        if len(matches) != 1:
            raise WorkspaceControlError("Project Git Project is unavailable")
        project = matches[0]
        project_root = _project_primary_path(project)
        getter = self.session_workspace_getter
        if not callable(getter):
            raise WorkspaceControlError("Project Git session ownership is unavailable")
        session_root = getter(agent_id, session_id)
        if inspect.isawaitable(session_root):
            session_root = await session_root
        if not _same_project_path(session_root, project_root):
            raise WorkspaceControlError("The session is not anchored to this Project")
        try:
            service = self.workspace_git or self._project_git_service(
                agent_id, workspace_id, project, project_root
            )
        except WorkspaceGitError as exc:
            raise _project_git_control_error(exc) from exc
        except (OSError, RuntimeError, ValueError) as exc:
            raise WorkspaceControlError(
                "Git is unavailable for this Project.",
                code="git_unavailable",
            ) from exc
        return {
            "values": values,
            "agent_id": agent_id,
            "session_id": session_id,
            "workspace_id": workspace_id,
            "service": service,
        }

    def _project_git_connection_id(self) -> str:
        getter = self.connection_id_getter
        value = getter() if callable(getter) else None
        if inspect.isawaitable(value):
            raise WorkspaceControlError("Project Git connection identity is unavailable")
        return _coordinate(value, 200)

    def _project_git_service(
        self,
        agent_id: str,
        workspace_id: str,
        project: dict[str, Any],
        project_root: str,
    ) -> WorkspaceGitService:
        policy = _project_git_policy(workspace_id, project_root)
        policy_digest = hashlib.sha256(
            json.dumps(policy, sort_keys=True, separators=(",", ":")).encode("utf-8")
        ).hexdigest()
        key = (agent_id, workspace_id, project_root, policy_digest)
        cached = self._project_git_services.get(key)
        if cached is not None:
            self._project_git_services.move_to_end(key)
            return cached
        service = WorkspaceGitService(
            [
                {
                    "workspace_id": workspace_id,
                    "label": _text(project.get("name"), 120),
                    "root": project_root,
                    **policy,
                }
            ],
            state_path=self.workspace_git_state_path,
        )
        self._project_git_services[key] = service
        while len(self._project_git_services) > 256:
            self._project_git_services.popitem(last=False)
        return service

    async def _project_projection(self, agent_id: str) -> dict[str, Any]:
        raw = _object(
            await self._projects_catalog(agent_id),
            "Hermes project catalog",
        )
        active_id = _optional_coordinate(raw.get("active_id"), 160)
        rows = raw.get("projects")
        if not isinstance(rows, list) or len(rows) > 256:
            raise WorkspaceControlError("Hermes project catalog is invalid")
        workspaces: list[dict[str, Any]] = []
        seen: set[str] = set()
        for value in rows:
            source = _object(value, "Hermes project")
            if source.get("archived") is True:
                continue
            workspace_id = _coordinate(source.get("id"), 160)
            if workspace_id in seen:
                raise WorkspaceControlError("Hermes project catalog is ambiguous")
            seen.add(workspace_id)
            folders = source.get("folders", [])
            if not isinstance(folders, list) or len(folders) > 10_000:
                raise WorkspaceControlError("Hermes project folder catalog is invalid")
            workspaces.append(
                {
                    "id": workspace_id,
                    "name": _text(source.get("name"), 160),
                    "description": _text(
                        source.get("description"), 4_096, allow_empty=True
                    ),
                    "folderCount": len(folders),
                    "isActive": workspace_id == active_id,
                }
            )
        if active_id is not None and active_id not in seen:
            active_id = None
        return {"activeWorkspaceId": active_id, "workspaces": workspaces}

    async def _projects_catalog(self, agent_id: str) -> dict[str, Any]:
        from hermes_cli import projects_db

        def load() -> dict[str, Any]:
            with _project_connection(agent_id, projects_db) as connection:
                return {
                    "active_id": projects_db.get_active_id(connection),
                    "projects": [
                        project.to_dict()
                        for project in projects_db.list_projects(
                            connection, include_archived=False
                        )
                    ],
                }

        return await asyncio.to_thread(load)

    async def _set_active_project(self, agent_id: str, project_id: str) -> str:
        from hermes_cli import projects_db

        def save() -> str:
            with _project_connection(agent_id, projects_db) as connection:
                project = projects_db.get_project(connection, project_id)
                if project is None or project.archived:
                    raise WorkspaceControlError("Workspace is unavailable")
                primary_path = project.primary_path or next(
                    (folder.path for folder in project.folders if folder.is_primary),
                    project.folders[0].path if project.folders else "",
                )
                resolved_path = _canonical_project_directory(primary_path)
                projects_db.set_active(connection, project_id)
                return resolved_path

        return await asyncio.to_thread(save)

    async def _project_directory(self, agent_id: str, project_id: str) -> str:
        raw = _object(
            await self._projects_catalog(agent_id),
            "Hermes project catalog",
        )
        rows = raw.get("projects")
        if not isinstance(rows, list) or len(rows) > 256:
            raise WorkspaceControlError("Hermes project catalog is invalid")
        matches = [
            _object(row, "Hermes project")
            for row in rows
            if isinstance(row, dict)
            and row.get("id") == project_id
            and row.get("archived") is not True
        ]
        if len(matches) != 1:
            raise WorkspaceControlError("Workspace is unavailable")
        return _canonical_project_directory(_project_primary_path(matches[0]))

    async def _create_project(
        self,
        agent_id: str,
        name: str,
        folder_path: str,
    ) -> None:
        from hermes_cli import projects_db

        def save() -> None:
            with _project_connection(agent_id, projects_db) as connection:
                project_id = projects_db.create_project(
                    connection,
                    name=name,
                    folders=[folder_path],
                    primary_path=folder_path,
                )
                projects_db.set_active(connection, project_id)

        await asyncio.to_thread(save)

    async def _archive_project(self, agent_id: str, project_id: str) -> None:
        from hermes_cli import projects_db

        def save() -> None:
            with _project_connection(agent_id, projects_db) as connection:
                project = projects_db.get_project(connection, project_id)
                if project is None or project.archived:
                    raise WorkspaceControlError("Workspace is unavailable")
                if not projects_db.archive_project(connection, project.id):
                    raise WorkspaceControlError("Workspace could not be archived")
                if projects_db.get_active_id(connection) == project.id:
                    projects_db.set_active(connection, None)

        await asyncio.to_thread(save)
