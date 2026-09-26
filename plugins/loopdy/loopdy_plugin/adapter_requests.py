"""Authenticated control requests, forms, catalogs, and session forks.

Operations use the calling LoopdyAdapter as their sole state/lifecycle owner.
Facade-owned callables and context variables are explicit call-time dependencies.
"""

from __future__ import annotations

import asyncio
import hashlib
import time
from dataclasses import replace
from typing import Any
from .inbound_dispatch import current_reply_route
from .link_client import (
    InboundLinkCommandCatalog,
    InboundLinkDeviceToolResult,
    InboundLinkDeviceToolStatus,
    InboundLinkDirectEnrollment,
    InboundLinkGenerativeUIFormSubmission,
    InboundLinkPersonalityRequest,
    InboundLinkSessionFork,
    InboundLinkVoiceSpeak,
    InboundLinkWorkspaceRequest,
)
from .link_contracts import (
    CommandCatalogRequest,
    command_catalog_payload,
    generative_ui_form_result,
    personality_catalog_payload,
    session_fork_result,
    verified_fork_prefix,
    workspace_capabilities,
    workspace_result,
    DIRECTED_FRAMES_CAPABILITY,
)
from .generative_ui import GenerativeUIError, validate_submission_values
from .store import form_action_response
from .workspace_control import WorkspaceControlError


def _submit_generative_ui_form(self, request: Any) -> dict[str, Any]:
    """Validate a Link form only against the host-owned rendered schema."""
    def failure(code):
        return form_action_response(request.request_id, request.idempotency_key, "error", code)

    try:
        stored = self.service.store.get_form_request(request.request_id)
        if stored is None:
            return failure("request_not_found")
        if (
            stored.get("profile") != request.profile
            or stored.get("session_id") != request.session_id
        ):
            return failure("owner_mismatch")
        values = validate_submission_values(
            stored.get("form_schema", {}),
            request.values,
        )
        return self.service.store.submit_form_request(
            request_id=request.request_id,
            profile=request.profile,
            session_id=request.session_id,
            idempotency_key=request.idempotency_key,
            values=values,
            now=int(time.time()),
        )
    except GenerativeUIError:
        return failure("invalid_value")
    except Exception:
        return failure("internal_error")


async def _build_link_command_catalog(
    self, request: CommandCatalogRequest
) -> list[dict[str, Any]]:
    from gateway.run import _profile_runtime_scope
    from hermes_cli.profiles import get_profile_dir, profile_exists

    if not profile_exists(request.agent_id):
        raise ValueError("The selected agent is unavailable")

    def load() -> list[dict[str, Any]]:
        from agent.skill_commands import get_skill_commands
        from agent.skill_utils import get_disabled_skill_names
        from cli import load_cli_config
        from hermes_cli.plugins import get_plugin_commands

        from .command_catalog import build_command_catalog

        skills = get_skill_commands()
        disabled = get_disabled_skill_names(platform="loopdy")
        filtered_skills = {
            key: value
            for key, value in skills.items()
            if not isinstance(value, dict)
            or value.get("name") not in disabled
        }
        config = load_cli_config()
        quick_commands = (
            config.get("quick_commands", {})
            if isinstance(config, dict)
            else {}
        )
        return build_command_catalog(
            plugin_commands=get_plugin_commands(),
            skill_commands=filtered_skills,
            quick_commands=quick_commands,
        )

    with _profile_runtime_scope(get_profile_dir(request.agent_id)):
        return await asyncio.to_thread(load)


async def _fork_link_session(
    self, inbound: InboundLinkSessionFork
) -> dict[str, Any]:
    request = inbound.request
    from gateway.run import _profile_runtime_scope
    from hermes_cli.profiles import get_profile_dir, profile_exists

    if not profile_exists(request.agent_id):
        raise ValueError("The selected agent is unavailable")
    with _profile_runtime_scope(get_profile_dir(request.agent_id)):
        source = self.build_source(
            chat_id=request.source_session_id,
            chat_name="Loopdy chat",
            chat_type="dm",
            user_id=inbound.sender_id,
            user_name=request.actor_name,
            message_id=request.request_id,
        )
        source.profile = request.agent_id
        source_entry = await self.async_session_store.get_or_create_session(
            source, touch_activity=False
        )
        history = await self.async_session_store.load_transcript(
            source_entry.session_id
        )
        prefix = verified_fork_prefix(history, request)

        target = self.build_source(
            chat_id=request.fork_session_id,
            chat_name="Loopdy chat",
            chat_type="dm",
            user_id=inbound.sender_id,
            user_name=request.actor_name,
            message_id=request.request_id,
        )
        target.profile = request.agent_id
        target_entry = await self.async_session_store.get_or_create_session(
            target, touch_activity=False
        )
        if target_entry.session_id == source_entry.session_id:
            raise ValueError("The fork coordinate already exists")
        existing = await self.async_session_store.load_transcript(
            target_entry.session_id
        )
        if existing:
            raise ValueError("The fork coordinate already exists")
        written = await self.async_session_store.rewrite_transcript(
            target_entry.session_id,
            prefix,
            reject_active_turn_lease=True,
        )
        if written is False:
            raise RuntimeError("Hermes did not persist the fork")

        db = getattr(self, "_session_db", None)
        if db is not None:
            source_row = await asyncio.to_thread(
                db.get_session, source_entry.session_id
            )
            await asyncio.to_thread(
                db.create_session,
                target_entry.session_id,
                "loopdy",
                model=(source_row or {}).get("model"),
                system_prompt=(source_row or {}).get("system_prompt"),
                parent_session_id=source_entry.session_id,
            )
            await asyncio.to_thread(
                db.set_session_title, target_entry.session_id, request.title
            )
    return session_fork_result(
        request=request,
        status="completed",
        title=request.title,
        message="Fork ready.",
        sent_at=int(time.time()),
    )


async def receive_direct_enrollment(self, payload: InboundLinkDirectEnrollment) -> None:
    runtime = self.direct_runtime
    client = self.link_client
    if runtime is None or client is None or current_reply_route.get() is not None:
        raise ValueError("direct enrollment is unavailable")
    if DIRECTED_FRAMES_CAPABILITY not in set(getattr(client, "peer_capabilities", ())):
        raise ValueError("directed enrollment is not negotiated")
    outcome = await runtime.enroll(payload.enrollment,
        sender_device_id=payload.sender_device_id, sender_epoch=payload.sender_epoch)
    await client.send_payload({"version": 1, "type": "direct.enrolled", "enrollment": outcome},
        target_device_id=payload.sender_device_id, owner_check=runtime.check_current)
    return


async def receive_workspace_request(
    self, payload: InboundLinkWorkspaceRequest, *,
    _MAX_LINK_METADATA_DEVICES: int, _link_workspace_connection,
) -> None:
    request = payload.request
    # Opt in only via the existing read-only operation; the v1 envelope
    # and controller operation permissions are unchanged.
    if (request.operation == "agents.list"
            and type(request.payload.get("linkProtocol")) is int
            and request.payload["linkProtocol"] == 1):
        request = replace(request, payload={
            key: value for key, value in request.payload.items()
            if key != "linkProtocol"
        })
        self._link_metadata_devices[payload.sender_device_id] = None
    negotiated = payload.sender_device_id in self._link_metadata_devices
    if negotiated:
        self._link_metadata_devices.move_to_end(payload.sender_device_id)
    while len(self._link_metadata_devices) > _MAX_LINK_METADATA_DEVICES:
        self._link_metadata_devices.popitem(last=False)
    route = current_reply_route.get()
    if request.operation.startswith("voice.live.") and route is None:
        route = self._link_reply_route(payload.sender_device_id, payload.sender_epoch or 0)
    connection_token = _link_workspace_connection.set(
        ("direct_" + hashlib.sha256(
            repr(route.owner).encode()).hexdigest())
        if route is not None and route.owner.transport == "direct"
        else payload.sender_device_id
    )
    try:
        if self.workspace_controller is None:
            raise RuntimeError("Workspace controls are unavailable")
        if request.operation.startswith("voice.live."):
            if payload.target_host_id != route.owner.host_id:
                raise ValueError("Live voice requires an exact host target")
            if "type" in request.payload:
                raise ValueError("Invalid live voice envelope")
            result_payload = await self._dispatch_live_voice(
                None, {"type": request.operation, **request.payload}, route)
        elif request.operation.startswith("wiki."):
            from .wiki_transport import WikiRequestContext
            wiki_context = WikiRequestContext(
                target_host_id=payload.target_host_id,
                device_id=payload.sender_device_id,
                authority_id=payload.authority_id,
                sender_epoch=payload.sender_epoch,
            )
            result_payload = await self.workspace_controller.execute(request, wiki_context=wiki_context)
        else:
            result_payload = await self.workspace_controller.execute(request)
        result = workspace_result(
            request=payload.request,
            status="completed",
            payload=result_payload,
            sent_at=int(time.time()),
        )
    except WorkspaceControlError as exc:
        result = workspace_result(
            request=payload.request,
            status=exc.status,
            payload={},
            code=exc.code,
            message=str(exc),
            sent_at=int(time.time()),
        )
    except ValueError:
        result = workspace_result(
            request=payload.request,
            status="conflict",
            payload={},
            code="workspace_conflict",
            message="The workspace changed. Refresh and try again.",
            sent_at=int(time.time()),
        )
    except Exception:
        result = workspace_result(
            request=payload.request,
            status="failed",
            payload={},
            code="workspace_unavailable",
            message="Hermes could not complete this workspace request.",
            sent_at=int(time.time()),
        )
    finally:
        _link_workspace_connection.reset(connection_token)
    if negotiated:
        result["capabilities"] = workspace_capabilities(
            direct_enrollment=self.direct_runtime is not None and self.direct_runtime.available)
        if result["status"] == "completed" and request.operation == "sessions.history":
            context = await self._workspace_history_context(request, result["payload"])
            if context is not None:
                result["context"] = context
    if self.link_client is not None:
        if request.operation.startswith("wiki."):
            from .wiki_service import WikiServiceError
            from .wiki_transport import authority_id
            response_client = self.link_client
            def check_response_owner():
                if (self.link_client is not response_client
                        or authority_id(self._wiki_current_config()) != payload.authority_id):
                    raise WikiServiceError("WIKI_OWNER_CHANGED", "Wiki response owner changed")
            await self._send_link_payload(result, owner_check=check_response_owner)
        else:
            await self._send_link_payload(result, reply_route=route)
        manager = getattr(getattr(self.workspace_controller, "backend", None), "plugin_update_manager", None)
        if (manager is not None and result["status"] == "completed"
                and request.operation != "host_runtime.status"):
            try:
                await asyncio.to_thread(manager.record_link_response, payload.sender_device_id)
            except Exception:
                # Optional update bookkeeping cannot break workspace delivery.
                pass
    return


async def receive_device_tool_status(self, payload: InboundLinkDeviceToolStatus) -> None:
    bridge = self.device_tool_bridge
    if bridge is not None:
        bridge.accept_status(
            payload.status,
            sender_device_id=payload.sender_device_id,
            sender_epoch=payload.sender_epoch,
            target_device_id=payload.target_device_id,
        )
    return


async def receive_device_tool_result(self, payload: InboundLinkDeviceToolResult) -> None:
    bridge = self.device_tool_bridge
    if bridge is not None:
        bridge.accept_result(
            payload.result,
            sender_device_id=payload.sender_device_id,
            sender_epoch=payload.sender_epoch,
            target_device_id=payload.target_device_id,
        )
    return


async def receive_form_submission(self, payload: InboundLinkGenerativeUIFormSubmission) -> None:
    response = await asyncio.to_thread(
        self._submit_generative_ui_form,
        payload.request,
    )
    if self.link_client is not None:
        await self._send_link_payload(
            generative_ui_form_result(
                request=payload.request,
                state=response["state"],
                code=response["code"],
                message=response["message"],
                sent_at=int(time.time()),
            )
        )
    return


async def receive_personality_request(self, payload: InboundLinkPersonalityRequest) -> None:
    catalog = await asyncio.to_thread(
        self.personality_manager.mutate,
        payload.request,
    )
    if self.link_client is not None:
        await self._send_link_payload(
            personality_catalog_payload(
                request_id=payload.request.request_id,
                catalog=catalog,
                sent_at=int(time.time()),
            )
        )
    return


async def receive_command_catalog(self, payload: InboundLinkCommandCatalog) -> None:
    commands = await self._build_link_command_catalog(payload.request)
    if self.link_client is not None:
        await self._send_link_payload(
            command_catalog_payload(
                request=payload.request,
                commands=commands,
                sent_at=int(time.time()),
            )
        )
    return


async def receive_session_fork(self, payload: InboundLinkSessionFork) -> None:
    try:
        result = await self._fork_link_session(payload)
    except ValueError as exc:
        result = session_fork_result(
            request=payload.request,
            status="conflict",
            title=payload.request.title,
            message=str(exc)[:2_000] or "The checkpoint changed. Try again.",
            sent_at=int(time.time()),
        )
    except Exception:
        result = session_fork_result(
            request=payload.request,
            status="failed",
            title=payload.request.title,
            message="Hermes could not create this fork. Try again.",
            sent_at=int(time.time()),
        )
    if self.link_client is not None:
        await self._send_link_payload(result)
    return


async def receive_voice_request(self, payload: InboundLinkVoiceSpeak) -> None:
    if len(self._voice_tasks) >= 4:
        raise ValueError("voice synthesis capacity exhausted")
    task = asyncio.create_task(
        self._serve_voice_request(payload.request),
        name=f"loopdy-voice-{payload.request.request_id}",
    )
    self._voice_tasks.add(task)
    task.add_done_callback(self._voice_tasks.discard)
    return
