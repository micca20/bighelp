"""Explicit workspace operation dispatch and shared backend composition.

Domain controls retain the HermesWorkspaceBackend method API and share its
injected dependencies and locks. Wiki remains separately context-authorized;
live voice is not part of this backend dispatch table.
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import inspect
import io
import json
import logging
import os
from pathlib import Path
import re
import stat
import sqlite3
import time
import zipfile
from collections import OrderedDict
from typing import Any
from .project_git_validation import ProjectGitValidation
from .workspace_operations import WORKSPACE_HANDLERS
from .attachments import AttachmentStore
from .generative_ui import GenerativeUIError, validate_rendered_envelope
from .generated_media import resolve_generated_media
from .host_runtime import InstalledHermesVersion
from . import plugin_update
from .link_contracts import (
    MAX_AGENT_ATTACHMENT_BYTES,
    MAX_ATTACHMENT_CHUNK_BYTES,
    PLUGIN_VERSION,
    AVAILABLE_WIKI_OPERATIONS,
    GROUPS_OPERATIONS,
    WORKSPACE_OPERATIONS,
    WorkspaceRequest,
    _workspace_json,
)
from .workspace_git import WorkspaceGitError, WorkspaceGitService
from . import workspace_capabilities
from .wiki_service import WikiServiceError
from .wiki_transport import WikiRequestContext, WikiTransport
from .session_state import (SessionStateReader, SessionStateNotFound,
                            SessionStateResetRequired, SessionStateUnavailable)

from .workspace_common import (
    WorkspaceConflictError,
    WorkspaceControlError,
    _AGENT_ID,
    _HermesMethodUnavailable,
    _agent_id,
    _agent_id_from_name,
    _agent_payload_id,
    _coordinate,
    _coordinate_list,
    _display_name,
    _empty_payload,
    _identifier,
    _nonnegative_integer,
    _object,
    _optional_coordinate,
    _optional_object,
    _optional_time_value,
    _text,
    _timestamp,
    _utf8_prefix,
    logger,
)
from .workspace_dashboard import (
    _DASHBOARD_EVENT_LIMIT,
    _DASHBOARD_RESPONSE_MAX_BYTES,
    _DASHBOARD_DETAIL_MAX_BYTES,

    _COMPLETION_EVENT_TYPES,
    _COMPLETION_SUMMARY_MAX_BYTES,
    _CRON_SESSION,
    _EVENT_DETAIL_KEYS,
    _approval_interaction_projection,
    _approval_projection,
    _clarify_interaction_projection,
    _completion_catalog,
    _cron_job_id,
    _event_projection,
    _event_projection_v2,
    _final_assistant_result,
    _interaction_projection,
)
from .workspace_profiles import (
    _PROFILE_CAPABILITY_MESSAGE,
    _ProfileCatalogUnavailable,
    _REASONING_VALUES,
    _agent_avatar_payload,
    _agent_avatar_projection,
    _agent_draft,
    _defaults,
    _model_identifier,
    _profile_has_avatar,
    _profile_ui_display_name,
    _provider_projection,
    _reasoning,
    _selection,
    _soul_digest,
    _soul_digest_coordinate,
)
from .workspace_projects import (
    _PROJECT_DIRECTORY_HIDDEN,
    _PROJECT_DIRECTORY_OFFSET_LIMIT,
    _PROJECT_DIRECTORY_PAGE_LIMIT,
    _absolute_project_path,
    _canonical_project_directory,
    _git_values,
    _project_directory_page,
    _project_directory_prefix,
    _project_git_choice,
    _project_git_control_error,
    _project_git_operation_input,
    _project_git_policy,
    _project_git_ref,
    _project_git_relative_path,
    _project_git_status_token,
    _project_git_wire,
    _project_primary_path,
    _same_project_path,
    _session_workspace_identity,
)
from .workspace_sessions import (
    _HISTORY_RICH_FIELDS,
    _HISTORY_ROLES,
    _SESSION_HISTORY_OFFSET_LIMIT,
    _SESSION_HISTORY_RESPONSE_MAX_BYTES,
    _reconcile_session_presentation,
    _stored_session_id_for_visible,
)
from .workspace_skills import (
    _SKILL_CATEGORY,
    _SKILL_IDENTIFIER,
    _SKILL_NAME,
    _SKILL_SUPPORT_ROOTS,
    _card_template_agent_id,
    _decode_skill_zip,
    _optional_skill_category,
    _sha256_coordinate,
    _skill_content,
    _skill_frontmatter_name,
    _skill_identifier,
    _skill_name,
    _skill_source_name,
    card_template_projection,
)
from .workspace_tasks import (
    _delivery_target_catalog,
    _scheduled_task_delivery,
    _scheduled_task_draft,
    _task_coordinate,
    _task_projection,
)
from .workspace_profiles import ProfileControls
from .workspace_skills import SkillControls
from .workspace_projects import ProjectControls
from .workspace_sessions import SessionControls
from .workspace_tasks import TaskControls
from .workspace_dashboard import DashboardControls


class HermesWorkspaceBackend(
    ProfileControls,
    SkillControls,
    ProjectControls,
    SessionControls,
    TaskControls,
    DashboardControls,
):
    """Validated projections over Hermes-owned services; one injected owner."""

    def __init__(
        self,
        *,
        service: Any,
        clock: Any = time.time,
        clarify_timeout: Any | None = None,
        session_workspace_setter: Any | None = None,
        session_workspace_getter: Any | None = None,
        session_active_getter: Any | None = None,
        session_subagents_getter: Any | None = None,
        session_goal_getter: Any | None = None,
        session_runtime_getter: Any | None = None,
        session_presentation_getter: Any | None = None,
        connection_id_getter: Any | None = None,
        plugin_update_manager: Any | None = None,
        workspace_git: WorkspaceGitService | Any | None = None,
        workspace_git_state_path: Path | str | None = None,
        attachment_store: AttachmentStore | None = None,
    ):
        self.service = service
        self.clock = clock
        self.clarify_timeout = clarify_timeout
        self.session_workspace_setter = session_workspace_setter
        self.session_workspace_getter = session_workspace_getter
        self.session_active_getter = session_active_getter
        self.session_subagents_getter = session_subagents_getter
        self.session_goal_getter = session_goal_getter
        self.session_runtime_getter = session_runtime_getter
        self.session_presentation_getter = session_presentation_getter
        self.connection_id_getter = connection_id_getter
        self.plugin_update_manager = plugin_update_manager
        self.workspace_git = workspace_git
        self.workspace_git_state_path = Path(
            workspace_git_state_path
            or Path(os.getenv("HERMES_HOME", Path.home() / ".hermes"))
            / "plugin-data"
            / "loopdy"
            / "workspace-git-link.sqlite3"
        )
        self.attachment_store = attachment_store or AttachmentStore(
            Path(os.getenv("HERMES_HOME", Path.home() / ".hermes"))
            / "plugin-data"
            / "loopdy"
            / "agent-attachments.sqlite3"
        )
        self._project_git_services: OrderedDict[
            tuple[str, str, str, str], WorkspaceGitService
        ] = OrderedDict()
        self._skill_update_locks: dict[tuple[str, str], asyncio.Lock] = {}
        self._capability_update_lock = asyncio.Lock()
        self._voice_settings_update_locks: dict[str, asyncio.Lock] = {}
        self._agent_catalog_compatibility = "unknown"
        self._installed_hermes_version = InstalledHermesVersion()

    async def host_runtime_status(self, payload: dict[str, Any]) -> dict[str, Any]:
        _empty_payload(payload)
        installed_version = await self._installed_hermes_version.get()
        identity = await asyncio.to_thread(plugin_update.runtime_identity)
        installed = identity["installed_revision"]
        active = identity["active_revision"]
        restart = "unknown"
        if installed and active:
            restart = "not_required" if installed == active else "required"
        compatibility = self._agent_catalog_compatibility
        unavailable = compatibility == "incompatible"
        return {
            "schemaVersion": 1,
            "runtimeId": identity["runtime_id"],
            "observedAt": int(self.clock()),
            "hermes": {
                # A separately invoked CLI cannot identify the running gateway.
                # Its local behindness text is not a fresh upstream check.
                "runningVersion": None,
                "cliVersion": installed_version,
                "updateState": "unknown",
                "updateCheckedAt": None,
                "restartState": "unknown",
            },
            "plugin": {
                "runningVersion": PLUGIN_VERSION,
                "installedRevision": installed,
                "activeRevision": active,
                "restartState": restart,
            },
            "compatibility": {
                "state": compatibility,
                "checkedOperations": [] if compatibility == "unknown" else ["agents.list"],
                "unavailableOperations": ["agents.list"] if unavailable else [],
                "issues": [{
                    "code": "hermes_capability_missing",
                    "operation": "agents.list",
                    "message": _PROFILE_CAPABILITY_MESSAGE,
                    "suggestedAction": "update_hermes",
                }] if unavailable else [],
            },
        }

    async def plugin_update_start(self, payload: dict[str, Any]) -> dict[str, Any]:
        values = _object(payload, "plugin update payload")
        if set(values) != {"operation_id", "confirm_restart"}:
            raise WorkspaceControlError("Plugin update payload is invalid")
        if values.get("confirm_restart") is not True:
            raise WorkspaceControlError("Gateway restart was not explicitly confirmed")
        operation_id = values.get("operation_id")
        if not isinstance(operation_id, str):
            raise WorkspaceControlError("Plugin update operation ID is invalid")
        manager = self.plugin_update_manager
        identity = self.connection_id_getter
        if manager is None or not callable(identity):
            raise WorkspaceControlError("Plugin update is unavailable on this host")
        device_id = identity()
        return await asyncio.to_thread(
            manager.start,
            operation_id=operation_id,
            device_id=device_id,
            restart=True,
        )

    async def plugin_update_status(self, payload: dict[str, Any]) -> dict[str, Any]:
        values = _object(payload, "plugin update payload")
        if set(values) - {"operation_id"}:
            raise WorkspaceControlError("Plugin update status payload is invalid")
        operation_id = values.get("operation_id")
        if operation_id is not None and not isinstance(operation_id, str):
            raise WorkspaceControlError("Plugin update operation ID is invalid")
        manager = self.plugin_update_manager
        identity = self.connection_id_getter
        if manager is None or not callable(identity):
            raise WorkspaceControlError("Plugin update is unavailable on this host")
        device_id = identity()

        def read_status() -> dict[str, Any]:
            manager.record_link_response(device_id, operation_id)
            return manager.status(operation_id=operation_id, device_id=device_id)

        return await asyncio.to_thread(read_status)

    async def _hermes_request(
        self,
        method: str,
        params: dict[str, Any],
        *,
        unavailable_message: str,
        request_id: str | None = None,
    ) -> dict[str, Any]:
        def dispatch() -> dict[str, Any]:
            from tui_gateway.server import handle_request

            resolved_request_id = request_id or f"loopdy-{method}"
            response = handle_request({
                "jsonrpc": "2.0",
                "id": resolved_request_id,
                "method": method,
                "params": params,
            })
            error = response.get("error") if isinstance(response, dict) else None
            if (
                isinstance(error, dict)
                and error.get("code") == -32601
            ):
                raise _HermesMethodUnavailable(unavailable_message)
            if (
                not isinstance(response, dict)
                or response.get("id") != resolved_request_id
                or "error" in response
                or not isinstance(response.get("result"), dict)
            ):
                raise WorkspaceControlError(unavailable_message)
            return dict(response["result"])

        return await asyncio.to_thread(dispatch)

    async def _groups_request(self, operation: str, payload: dict[str, Any]) -> dict[str, Any]:
        """Forward Hermes' native hosted-room RPC without reimplementing it."""
        return await self._hermes_request(
            operation,
            payload,
            unavailable_message="Hermes native Bot Mode is unavailable on this gateway",
            request_id=f"loopdy-{operation}",
        )

    async def groups_capabilities(self, payload: dict[str, Any]) -> dict[str, Any]:
        return await self._groups_request("groups.capabilities", payload)

    async def groups_list(self, payload: dict[str, Any]) -> dict[str, Any]:
        return await self._groups_request("groups.list", payload)

    async def groups_create(self, payload: dict[str, Any]) -> dict[str, Any]:
        return await self._groups_request("groups.create", payload)

    async def groups_state(self, payload: dict[str, Any]) -> dict[str, Any]:
        return await self._groups_request("groups.state", payload)

    async def groups_send(self, payload: dict[str, Any]) -> dict[str, Any]:
        return await self._groups_request("groups.send", payload)

    async def groups_rename(self, payload: dict[str, Any]) -> dict[str, Any]:
        return await self._groups_request("groups.rename", payload)

    async def groups_log(self, payload: dict[str, Any]) -> dict[str, Any]:
        return await self._groups_request("groups.log", payload)

    async def groups_disband(self, payload: dict[str, Any]) -> dict[str, Any]:
        return await self._groups_request("groups.disband", payload)

    async def groups_replicate(self, payload: dict[str, Any]) -> dict[str, Any]:
        return await self._groups_request("groups.replicate", payload)

    async def groups_replica_state(self, payload: dict[str, Any]) -> dict[str, Any]:
        return await self._groups_request("groups.replica_state", payload)

    async def groups_promote(self, payload: dict[str, Any]) -> dict[str, Any]:
        return await self._groups_request("groups.promote", payload)

    async def groups_demote(self, payload: dict[str, Any]) -> dict[str, Any]:
        return await self._groups_request("groups.demote", payload)

    async def groups_stop(self, payload: dict[str, Any]) -> dict[str, Any]:
        return await self._groups_request("groups.stop", payload)

    async def groups_retry(self, payload: dict[str, Any]) -> dict[str, Any]:
        return await self._groups_request("groups.retry", payload)

    async def groups_approve(self, payload: dict[str, Any]) -> dict[str, Any]:
        return await self._groups_request("groups.approve", payload)

    async def groups_peer_invite(self, payload: dict[str, Any]) -> dict[str, Any]:
        return await self._groups_request("groups.peer.invite", payload)

    async def groups_peer_revoke(self, payload: dict[str, Any]) -> dict[str, Any]:
        return await self._groups_request("groups.peer.revoke", payload)

    async def groups_peer_register(self, payload: dict[str, Any]) -> dict[str, Any]:
        return await self._groups_request("groups.peer.register", payload)


class WorkspaceController:
    _HANDLERS = {
        **{operation: "wiki" for operation in AVAILABLE_WIKI_OPERATIONS},
        **WORKSPACE_HANDLERS,
    }

    def __init__(self, *, backend: Any, wiki_transport: WikiTransport | None = None):
        self.backend = backend
        self.wiki_transport = wiki_transport

    @property
    def operations(self) -> frozenset[str]:
        return frozenset(self._HANDLERS)

    async def execute(self, request: WorkspaceRequest, *,
                      wiki_context: WikiRequestContext | None = None) -> dict[str, Any]:
        if request.operation in AVAILABLE_WIKI_OPERATIONS:
            if self.wiki_transport is None:
                raise WorkspaceControlError("Wiki is unavailable on this host", code="WIKI_UNAVAILABLE")
            try:
                result = await asyncio.to_thread(
                    self.wiki_transport.execute, request.operation, dict(request.payload), context=wiki_context,
                )
                self.wiki_transport.check_context(wiki_context)
                return result
            except WikiServiceError as error:
                raise WorkspaceControlError(error.message, code=error.code) from None
            except Exception:
                raise WorkspaceControlError("Wiki request could not be completed", code="WIKI_UNAVAILABLE") from None
        handler_name = self._HANDLERS.get(request.operation)
        if handler_name is None or request.operation not in WORKSPACE_OPERATIONS:
            raise WorkspaceControlError("Unsupported Loopdy workspace operation")
        handler = getattr(self.backend, handler_name, None)
        if not callable(handler):
            raise WorkspaceControlError("Loopdy workspace operation is unavailable")
        result = handler(dict(request.payload))
        if inspect.isawaitable(result):
            result = await result
        if not isinstance(result, dict):
            raise WorkspaceControlError("Loopdy workspace result is invalid")
        return result

if frozenset(WorkspaceController._HANDLERS) != WORKSPACE_OPERATIONS:
    raise RuntimeError("Loopdy workspace operations and controller handlers diverged")

__all__ = [
    "HermesWorkspaceBackend",
    "WorkspaceConflictError",
    "WorkspaceControlError",
    "WorkspaceController",
]
