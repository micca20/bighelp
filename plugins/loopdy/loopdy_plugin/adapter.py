"""Public Loopdy adapter facade and the sole lifecycle/state owner.

Stateless adapter_* modules implement cohesive operations against this owner.
Keep admission, processing hooks, construction, teardown and public signatures
here; pass facade-owned compatibility seams explicitly when delegating.
"""

from __future__ import annotations

import asyncio
import contextvars
import hashlib
import inspect
import json
import logging
import os
import tempfile
import threading
import time
from collections import OrderedDict
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any, Callable, Dict, Optional

from gateway.config import Platform, PlatformConfig
from gateway.platforms.base import (
    BasePlatformAdapter,
    EphemeralReply,
    MessageEvent,
    ProcessingOutcome,
    SendResult,
)
from gateway.session import SessionSource, build_session_key
from hermes_constants import get_hermes_home

from .inbound_dispatch import (
    AuthenticatedRequestOwner, ReplyRoute, TurnReplyRegistry, DirectResponseCapture,
    AttachmentUnavailable, parse_authenticated_payload, current_reply_route, current_turn_lease,
)
from .direct_runtime import DirectRuntime, DirectSettings, runtime_owner
from .control_replies import capture_control_replies, capture_control_reply
from .events import EVENT_TYPES, LoopdyEvent, build_event
from .link_client import (
    InboundLinkDirectEnrollment,
    InboundLinkCommandCatalog,
    InboundLinkDeviceToolResult,
    InboundLinkDeviceToolStatus,
    InboundLinkGenerativeUIFormSubmission,
    InboundLinkPersonalityRequest,
    InboundLinkPickerOpen,
    InboundLinkPickerSelection,
    InboundLinkRelayReady,
    InboundLinkSessionFork,
    InboundLinkTurn,
    InboundLinkVoiceSpeak,
    InboundLinkWorkspaceRequest,
    LoopdyLinkClient,
    load_runtime_config,
)
from .link_contracts import (
    CommandCatalogRequest,
    PickerOpen,
    PickerSelection,
    SessionForkRequest,
    VoiceSpeakRequest,
    WorkspaceRequest,
    _session_coordinate,
    assistant_message,
    choice_picker_payload,
    command_catalog_payload,
    generative_ui_form_result,
    model_picker_payload,
    notification_event,
    picker_result,
    personality_catalog_payload,
    session_context,
    session_fork_result,
    verified_fork_prefix,
    voice_audio_chunks,
    voice_speak_error,
    workspace_capabilities,
    workspace_result,
    DEVICE_TOOL_CAPABILITY,
    DIRECTED_FRAMES_CAPABILITY,
    DIRECT_ENROLLMENT_CAPABILITY,
    STATE_BACKED_PRESENTATION_CAPABILITY,
)
from .device_tools import DeviceToolBridge
from .generative_ui import (
    GenerativeUIError,
    parse_v2_json,
    validate_rendered_envelope,
    validate_submission_values,
)
from .link_crypto import encode_base64url
from .personality_catalog import PersonalityCatalogManager
from .plugin_update import PluginUpdateManager
from .presentation import shape_notification
from .service import LoopdyService
from .store import LoopdyStore, form_action_response
from .targets import parse_target, validate_target
from .workspace_control import (
    HermesWorkspaceBackend,
    WorkspaceControlError,
    WorkspaceController,
)


# Operations are stateless; this facade owns construction, lifecycle and state.
from . import (
    adapter_delivery, adapter_pickers, adapter_presentation,
    adapter_requests, adapter_sessions, adapter_transport, adapter_voice,
)
from .adapter_pickers import _ActivePicker, _PendingPickerRequest
from .adapter_voice import SynthesizedVoiceAudio, VoiceSynthesisError, synthesize_voice_audio


_services: dict[str, LoopdyService] = {}
_services_lock = threading.Lock()
logger = logging.getLogger(__name__)
_MAX_LINK_SESSION_PROFILE_BINDINGS = 4096
_MAX_LINK_DRAFT_IDENTITIES = 512
_MAX_LINK_METADATA_DEVICES = 256
_LINK_DRAFT_MINIMUM_INTERVAL_SECONDS = 0.25
_RUNTIME_CWD_BRIDGE_MARKER = "_loopdy_runtime_cwd_bridge_installed"
_suppress_link_control_ephemeral: contextvars.ContextVar[bool] = contextvars.ContextVar(
    "suppress_link_control_ephemeral",
    default=False,
)
_link_workspace_connection: contextvars.ContextVar[str] = contextvars.ContextVar(
    "link_workspace_connection",
    default="",
)
_picker_request_id: contextvars.ContextVar[str] = contextvars.ContextVar(
    "loopdy_picker_request_id",
    default="",
)


def tool_execution_context_type() -> Any:
    """Require both halves of the optional host context contract."""
    if "tool_execution_context" not in inspect.signature(MessageEvent).parameters:
        return None
    try:
        from tool_execution_context import ToolExecutionContext
    except (ImportError, AttributeError):
        return None
    return ToolExecutionContext if callable(ToolExecutionContext) else None


def _verified_tool_execution_context(link_client: Any, turn: InboundLinkTurn) -> Any:
    """Map only verified Link frame coordinates into Hermes' generic context."""
    context_type = tool_execution_context_type()
    if turn.sender_epoch is None or context_type is None:
        return None
    config = getattr(link_client, "config", None)
    host_id = turn.target_host_id or getattr(config, "device_id", "")
    if not host_id or host_id != getattr(config, "device_id", host_id):
        return None
    return context_type(
        source="loopdy_link",
        owner_id=turn.sender_device_id,
        scope_id=turn.message.agent_id,
        authorization_epoch=turn.sender_epoch,
        attributes={
            "host_id": host_id,
        },
    )


def data_path() -> Path:
    return get_hermes_home() / "plugin-data" / "loopdy" / "loopdy.sqlite3"


def get_service() -> LoopdyService:
    key = str(data_path().resolve())
    with _services_lock:
        service = _services.get(key)
        if service is None:
            service = LoopdyService(LoopdyStore(Path(key)))
            _services[key] = service
        return service


def release_service(service: LoopdyService) -> None:
    service.close()
    with _services_lock:
        for key, cached in list(_services.items()):
            if cached is service:
                del _services[key]


def _loopdy_runtime_cwd(runner: Any, context: Any) -> str | None:
    """Resolve one Loopdy turn's live Hermes cwd without global process state."""
    source = getattr(context, "source", None)
    if getattr(getattr(source, "platform", None), "value", None) != "loopdy":
        return None

    session_key = str(getattr(context, "session_key", "") or "").strip()
    session_id = str(getattr(context, "session_id", "") or "").strip()

    from tools.terminal_tool import get_session_cwd

    for coordinate in (session_key, session_id):
        if not coordinate:
            continue
        cwd = get_session_cwd(coordinate)
        if isinstance(cwd, str) and cwd.strip():
            return cwd.strip()

    if not session_id:
        return None
    session_store = getattr(runner, "session_store", None)
    if session_store is None:
        return None
    db_for_session_id = getattr(session_store, "_db_for_session_id", None)
    session_db = (
        db_for_session_id(session_id)
        if callable(db_for_session_id)
        else getattr(session_store, "_db", None)
    )
    get_session = getattr(session_db, "get_session", None)
    row = get_session(session_id) if callable(get_session) else None
    cwd = row.get("cwd") if isinstance(row, dict) else None
    if isinstance(cwd, str) and cwd.strip():
        return cwd.strip()
    return None


def _install_runtime_cwd_bridge(runner: Any) -> None:
    """Restore Loopdy's task-local cwd after Hermes binds session variables."""
    if runner is None or getattr(runner, _RUNTIME_CWD_BRIDGE_MARKER, False):
        return
    original = getattr(runner, "_set_session_env", None)
    if not callable(original):
        return

    def set_session_env_with_loopdy_cwd(context: Any) -> list:
        tokens = original(context)
        try:
            cwd = _loopdy_runtime_cwd(runner, context)
            if cwd:
                from agent.runtime_cwd import set_session_cwd
                from tools.terminal_tool import register_task_env_overrides

                set_session_cwd(cwd)
                override = {"cwd": cwd, "cwd_source": "project"}
                for coordinate in (
                    str(getattr(context, "session_key", "") or "").strip(),
                    str(getattr(context, "session_id", "") or "").strip(),
                ):
                    if coordinate:
                        register_task_env_overrides(coordinate, override)
        except Exception:
            logger.warning(
                "Loopdy could not restore Hermes runtime cwd for session %s",
                str(getattr(context, "session_id", "") or "")[:80],
                exc_info=True,
            )
        return tokens

    runner._set_session_env = set_session_env_with_loopdy_cwd
    setattr(runner, _RUNTIME_CWD_BRIDGE_MARKER, True)


class LoopdyAdapter(BasePlatformAdapter):
    """Own transport generations, turn leases, tasks, caches and delivery state."""

    supports_async_delivery = True
    interactive_resume = False
    # Own message sizing: card envelopes must reach validation intact, while
    # ordinary Inbox text is split below rather than cut by Hermes cron delivery.
    splits_long_messages = True

    def __init__(
        self,
        config: PlatformConfig,
        *,
        service: LoopdyService | None = None,
        link_client: LoopdyLinkClient | Any | None = None,
        link_state: Any | None = None,
        activity_broker: Any | None = None,
        personality_manager: PersonalityCatalogManager | Any | None = None,
        workspace_controller: Any | None = None,
        plugin_update_manager: PluginUpdateManager | None = None,
        device_tool_bridge: DeviceToolBridge | None = None,
        wiki_transport: Any | None = None,
        direct_settings: DirectSettings | None = None,
        direct_settings_getter: Callable | None = None,
        direct_runtime_factory: Callable = DirectRuntime,
        direct_session_opener: Callable | None = None,
        presentation_observer: Callable | None = None,
        voice_dispatch: Callable | None = None,
        live_voice_settings_getter: Callable | None = None,
        live_voice_provider_factory: Callable | None = None,
        live_voice_storage_root: Path | None = None,
        voice_synthesizer: Callable[[VoiceSpeakRequest], SynthesizedVoiceAudio] = synthesize_voice_audio,
    ):
        # Restart and shutdown pings are operator lifecycle signals, not user
        # inbox content. Loopdy presents connection health in its device UI.
        config.gateway_restart_notification = False
        super().__init__(config=config, platform=Platform("loopdy"))
        self.service = service or get_service()
        self.home_target = str((config.extra or {}).get("home_target") or "all").strip()
        self.link_client = link_client
        self.direct_settings = direct_settings or DirectSettings()
        self._direct_settings_getter = direct_settings_getter
        self._direct_runtime_factory = direct_runtime_factory
        self.direct_runtime = None
        self.direct_configuration_error = ""
        self._direct_start_task = None
        self._direct_session_opener = direct_session_opener
        self._presentation_lock = threading.RLock()
        self._session_presentation = None
        self._presentation_hub = None
        self._presentation_owner = None
        self._presentation_scopes: OrderedDict[tuple[str, str], dict[str, Any]] = OrderedDict()
        self._presentation_evicted = False
        self._presentation_runs = {}
        self._presentation_observer = presentation_observer
        self._voice_dispatch = voice_dispatch
        self._live_voice_runtime = None
        self._live_voice_settings_getter = live_voice_settings_getter
        self._live_voice_provider_factory = live_voice_provider_factory
        self._live_voice_storage_root = live_voice_storage_root
        self._turn_replies = TurnReplyRegistry()
        self._processing_turns = set()
        self._transport_generation = encode_base64url(os.urandom(18))
        self._link_state = link_state
        self._control_response_task: contextvars.ContextVar[Any] = contextvars.ContextVar("loopdy_control_task", default=None)
        self._busy_response: contextvars.ContextVar[Any] = contextvars.ContextVar("loopdy_busy_response", default=None)
        self._wiki_uses_runtime_config = link_client is None
        from .wiki_transport import production_factory
        self.wiki_transport = wiki_transport or production_factory(
            host_home=get_hermes_home(), config_getter=self._wiki_current_config,
        )
        self.activity_broker = activity_broker
        self.device_tool_bridge = device_tool_bridge or DeviceToolBridge()
        self.personality_manager = personality_manager or PersonalityCatalogManager(
            config_path=get_hermes_home() / "config.yaml"
        )
        self.workspace_controller = workspace_controller or WorkspaceController(
            wiki_transport=self.wiki_transport,
            backend=HermesWorkspaceBackend(
                service=self.service,
                session_workspace_setter=self._set_link_session_workspace,
                session_workspace_getter=self._get_link_session_workspace,
                session_active_getter=self._is_link_session_active,
                session_subagents_getter=(
                    getattr(self.activity_broker, "subagent_snapshot", None)
                ),
                session_goal_getter=self.goal_snapshot_for_session,
                session_runtime_getter=self.runtime_snapshot_for_session,
                session_presentation_getter=self.session_presentation_snapshot,
                connection_id_getter=self._link_workspace_connection_id,
                plugin_update_manager=plugin_update_manager,
                workspace_git_state_path=(
                    get_hermes_home()
                    / "plugin-data"
                    / "loopdy"
                    / "workspace-git-link.sqlite3"
                ),
            )
        )
        self.voice_synthesizer = voice_synthesizer
        self._voice_tasks: set[asyncio.Task[None]] = set()
        self._pending_picker_requests: dict[str, _PendingPickerRequest] = {}
        self._active_pickers: dict[str, _ActivePicker] = {}
        self._link_metadata_devices: OrderedDict[str, None] = OrderedDict()
        self._link_session_profiles: OrderedDict[str, str] = OrderedDict()
        self._link_session_workspaces: OrderedDict[tuple[str, str], str] = OrderedDict()
        self._link_draft_messages: OrderedDict[tuple[str, int], str] = OrderedDict()
        self._link_active_drafts: OrderedDict[
            tuple[str, str], tuple[tuple[str, int], str]
        ] = OrderedDict()
        self._link_draft_sent_at: OrderedDict[tuple[str, str], float] = OrderedDict()
        self._link_delivery_lock = asyncio.Lock()
        self.link_configuration_error = ""
        # Native Hermes owns production chat. Saved Link configuration is retained
        # for optional notification enrollment, never used to construct a chat
        # socket, account catalog, cloud outbox, or paired Direct listener.
        # An explicitly injected legacy client remains usable by protocol tests.
        if self.link_client is not None and getattr(self.link_client, "config", None) is not None:
            self.device_tool_bridge.bind_link_client(self.link_client)

        self._start_session_presentation()

    def _wiki_current_config(self):
        from .wiki_transport import authority_id
        client = self.link_client
        if client is None or getattr(client, "_authentication_failed", False):
            return None
        stopping = getattr(client, "_stopping", None)
        if stopping is not None and stopping.is_set():
            return None
        config = client.config
        if self._wiki_uses_runtime_config:
            current = load_runtime_config()
            if current is None or authority_id(current) != authority_id(config):
                return None
        return config

    @property
    def authorization_is_upstream(self) -> bool:
        # User/device authorization is completed by the signed Link socket;
        # message identity is then authenticated again by the account AEAD.
        return self.link_client is not None

    def set_session_store(self, session_store: Any) -> None:
        super().set_session_store(session_store)
        _install_runtime_cwd_bridge(getattr(self, "gateway_runner", None))
        attach = getattr(self.activity_broker, "attach_session_store", None)
        if callable(attach):
            attach(session_store)
        attach_context = getattr(self.activity_broker, "attach_context_provider", None)
        if callable(attach_context):
            attach_context(self._context_window_snapshot)
        attach_goal = getattr(self.activity_broker, "attach_goal_provider", None)
        if callable(attach_goal):
            attach_goal(self._goal_state_snapshot)

    def _goal_state_snapshot(self, session_id: str) -> dict[str, Any] | None:
        return adapter_sessions._goal_state_snapshot(self, session_id, _is_link_chat_id=_is_link_chat_id)

    async def runtime_snapshot_for_session(self, agent_id: str, stored_id: str) -> dict[str, str] | None:
        return await adapter_sessions.runtime_snapshot_for_session(self, agent_id, stored_id)

    async def goal_snapshot_for_session(
        self, agent_id: str, session_id: str, stored_id: str
    ) -> dict[str, Any] | None:
        return await adapter_sessions.goal_snapshot_for_session(
            self, agent_id, session_id,
            stored_id, logger=logger,
        )

    async def _refresh_goal_for_source(self, source: SessionSource) -> None:
        return await adapter_sessions._refresh_goal_for_source(self, source, logger=logger)

    def _context_window_snapshot(self, session_id: str) -> dict[str, Any] | None:
        return adapter_sessions._context_window_snapshot(self, session_id, logger=logger)

    def set_voice_dispatch(self, dispatcher: Callable | None) -> None:
        """Bind a plugin-owned voice coordinator after adapter construction."""
        if dispatcher is not None and not callable(dispatcher):
            raise TypeError("voice dispatcher must be callable")
        self._voice_dispatch = dispatcher

    def _ensure_live_voice_runtime(self):
        if self._live_voice_runtime is None:
            from .live_voice_runtime import LiveVoiceRuntime
            self._live_voice_runtime = LiveVoiceRuntime(
                self, storage_root=self._live_voice_storage_root or
                get_hermes_home() / "plugin-data" / "loopdy" / "live-voice",
                provider_factory=self._live_voice_provider_factory,
                settings_getter=self._live_voice_settings_getter)
        return self._live_voice_runtime

    async def _dispatch_live_voice(self, context, payload, route):
        dispatch = self._voice_dispatch or self._ensure_live_voice_runtime().dispatch
        return await dispatch(context, payload, route)

    def _direct_current_config(self):
        # Configuration is reread without depending on the relay socket's state.
        if self._wiki_uses_runtime_config:
            return load_runtime_config()
        return getattr(self.link_client, "config", None)

    def _on_direct_status(self, runtime, available):
        if self.direct_runtime is not runtime:
            return
        if available or bool(getattr(self.link_client, "connected", False)):
            self._mark_connected()
        else:
            self._mark_disconnected()
        if runtime.retired:
            # A listener-only configuration change must not erase relay state;
            # a changed pairing must. This lifecycle callback may read config,
            # unlike the synchronous broker capture hook.
            try:
                config = self._direct_current_config()
                owner = runtime_owner(config) if config is not None else None
            except Exception:
                owner = None
            if owner != self._presentation_owner:
                self._close_session_presentation()
            self.device_tool_bridge.retire_direct(runtime.generation)
            self._pending_picker_requests = {
                key: value for key, value in self._pending_picker_requests.items()
                if value.route is None or value.route.owner.generation != runtime.generation}
            self._active_pickers = {
                key: value for key, value in self._active_pickers.items()
                if value.route is None or value.route.owner.generation != runtime.generation}

    def _start_session_presentation(self):
        return adapter_presentation._start_session_presentation(self)

    def _close_session_presentation(self):
        return adapter_presentation._close_session_presentation(self)

    def _check_presentation_owner(self):
        return adapter_presentation._check_presentation_owner(self)

    def _presentation_scope(self, agent_id, session_id):
        return adapter_presentation._presentation_scope(self, agent_id, session_id)

    def _admit_presentation_scope(self, scope):
        return adapter_presentation._admit_presentation_scope(self, scope)

    def _capture_broker_presentation(self, payload):
        return adapter_presentation._capture_broker_presentation(self, payload)

    async def _send_broker_payload(self, payload):
        return await adapter_transport._send_broker_payload(self, payload)

    def _capture_session_presentation(self, agent_id, payload):
        return adapter_presentation._capture_session_presentation(self, agent_id, payload)

    def session_presentation_snapshot(self, agent_id: str, session_id: str) -> dict[str, Any]:
        return adapter_presentation.session_presentation_snapshot(self, agent_id, session_id)

    def _require_captured_draft(self, payload):
        return adapter_presentation._require_captured_draft(self, payload)

    async def _start_direct(self) -> bool:
        return await adapter_transport._start_direct(self, get_hermes_home=get_hermes_home)

    async def _wait_for_transport(self) -> bool:
        # Direct startup remains adapter-owned after relay readiness.
        return await adapter_transport._wait_for_transport(self)

    def _observe_presentation(self, event_name: str, **coordinates) -> bool:
        return adapter_presentation._observe_presentation(self, event_name, coordinates, logger=logger)

    async def open_direct_session(self, context, agent_id: str, session_id: str):
        return await adapter_transport.open_direct_session(self, context, agent_id, session_id)

    async def _open_session_snapshot(self, runtime, context, agent_id, session_id):
        return await adapter_presentation._open_session_snapshot(self, runtime, context, agent_id, session_id)

    async def dispatch_direct(self, context, payload: dict[str, Any]) -> dict[str, Any]:
        return await adapter_transport.dispatch_direct(self, context, payload)

    @staticmethod
    def _user_message_result(request, *, status, code=None, **details):
        result = {"version": 1, "type": "user.message.result", "requestId": request.message_id,
                  "sessionId": request.session_id, "agentId": request.agent_id,
                  "status": status, "sentAt": int(time.time())}
        if code is not None:
            result["code"] = code
        result.update(details)
        return result

    def _link_reply_route(self, device_id: str, device_epoch: int = 0) -> ReplyRoute:
        return adapter_transport._link_reply_route(self, device_id, device_epoch)

    def _response_route(self, chat_id, metadata, reply_to=None):
        inherited = current_turn_lease.get()
        profile = self._link_response_profile(chat_id, metadata)
        message_id = reply_to or metadata.get("reply_to_message_id")
        return self._turn_replies.resolve(profile, chat_id, message_id, inherited)

    async def connect(self, *, is_reconnect: bool = False) -> bool:
        plugin_update_manager = getattr(
            getattr(self.workspace_controller, "backend", None),
            "plugin_update_manager",
            None,
        )
        if plugin_update_manager is not None:
            # Adapter connection is a real gateway lifecycle. Plugin Doctor
            # and CLI discovery register the plugin but never reach here.
            try:
                plugin_update_manager.record_runtime_loaded()
            except Exception:
                # Update status can fail closed without disabling ordinary Link.
                pass
        if self.link_client is None:
            self._mark_connected()
            return True
        health = self.service.health()
        has_direct_owner = self.direct_runtime is not None or (self._direct_start_task and not self._direct_start_task.done())
        if has_direct_owner and not is_reconnect:
            await self.disconnect()
        self._start_session_presentation()
        runtime = self.direct_runtime
        if runtime is not None and (runtime.retired or runtime.hub is not self._presentation_hub):
            await runtime.stop()
            self.direct_runtime = None
        if self.direct_runtime is None and (self._direct_start_task is None or self._direct_start_task.done()):
            self._direct_start_task = asyncio.create_task(self._start_direct(), name="loopdy-direct-start")
        if self.link_client is not None:
            try:
                self.device_tool_bridge.bind_link_client(self.link_client)
                self.link_client.start(
                    self.receive_link_payload, status_callback=self._on_link_status)
                if self.activity_broker is not None:
                    await self.activity_broker.attach(
                        self._send_broker_payload,
                        live_activity_sender=self.link_client.send_live_activity_update)
                usable = await self._wait_for_transport()
            except BaseException:
                await self.disconnect()
                raise
            if not usable:
                detail = "Loopdy Link did not complete the socket-ready handshake."
                link_state = "disconnected"
                status = getattr(self.link_client, "status", None)
                if callable(status):
                    try:
                        snapshot = status()
                        detail = str(snapshot.get("detail") or detail)[:160]
                        link_state = str(snapshot.get("state") or link_state)
                    except Exception:
                        pass
                superseded = link_state == "superseded"
                self._set_fatal_error(
                    (
                        "loopdy_link_superseded"
                        if superseded
                        else "loopdy_link_not_ready"
                    ),
                    detail,
                    retryable=not superseded,
                )
                await self.disconnect()
                return False
        if not health.get("configured") and self.link_client is None:
            self._set_fatal_error(
                (
                    "loopdy_link_configuration_invalid"
                    if self.link_configuration_error
                    else "loopdy_provider_not_ready"
                ),
                self.link_configuration_error
                or str(health.get("detail") or "Configure Loopdy notifications first."),
                retryable=False,
            )
            await self.disconnect()
            return False
        self._mark_connected()
        return True

    async def _wait_for_link_connection(self) -> bool:
        client = self.link_client
        if client is None:
            return False
        wait = getattr(client, "wait_until_connected", None)
        if callable(wait):
            try:
                return bool(await wait(timeout=20.0))
            except asyncio.CancelledError:
                raise
            except Exception:
                return False
        return bool(getattr(client, "connected", False))

    def _on_link_status(self, state: str, detail: str = "") -> None:
        voice = self._live_voice_runtime
        if voice is not None and state != "connected":
            voice.transport_lost(transport="link",
                revoked=state in {"authentication_error", "superseded", "unready"})
        if state in {"authentication_error", "superseded"}:
            self._close_session_presentation()
            if self.direct_runtime is not None:
                self.direct_runtime.retire()
        if state != "connected" and self.direct_runtime is not None and self.direct_runtime.available:
            self._mark_connected()
            return
        if state == "connected":
            self._mark_connected()
        elif state == "unready":
            self._set_fatal_error(
                "loopdy_link_enrollment_unready",
                detail or "Loopdy Link enrollment is not ready.",
                retryable=True,
            )
        elif state == "superseded":
            self._set_fatal_error(
                "loopdy_link_superseded",
                detail or "A newer Hermes runtime owns this Loopdy Link device.",
                retryable=False,
            )
        elif state in {"disconnected", "reconnecting"}:
            self._mark_disconnected()

    async def _send_link_payload(self, payload: dict[str, Any], *,
                                 owner_check: Callable[[], None] | None = None,
                                 reply_route: ReplyRoute | None = None) -> str:
        return await adapter_transport._send_link_payload(
            self, payload, owner_check=owner_check,
            reply_route=reply_route,
        )

    async def _deliver_link_notification(
        self,
        event: LoopdyEvent,
        *,
        target: str,
    ) -> SendResult:
        return await adapter_delivery._deliver_link_notification(self, event, target=target)

    async def _deliver_link_notification_locked(
        self,
        event: LoopdyEvent,
        *,
        target: str,
    ) -> SendResult:
        return await adapter_delivery._deliver_link_notification_locked(self, event, target=target)

    async def disconnect(self) -> None:
        voice, self._live_voice_runtime = self._live_voice_runtime, None
        if voice is not None:
            await voice.shutdown()
        self._transport_generation = encode_base64url(os.urandom(18))
        start, self._direct_start_task = self._direct_start_task, None
        if start is not None and not start.done():
            start.cancel()
            await asyncio.gather(start, return_exceptions=True)
        runtime, self.direct_runtime = self.direct_runtime, None
        self._close_session_presentation()
        if runtime is not None:
            await runtime.stop()
            self._observe_presentation("runtime_stopped", runtime=runtime)
        self._turn_replies.clear()
        self._processing_turns.clear()
        self.device_tool_bridge.bind_link_client(None)
        if self.activity_broker is not None:
            await self.activity_broker.detach()
        active_voice_tasks = tuple(self._voice_tasks)
        for task in active_voice_tasks:
            task.cancel()
        if active_voice_tasks:
            await asyncio.gather(*active_voice_tasks, return_exceptions=True)
        if self.link_client is not None:
            await self.link_client.stop()
        self._pending_picker_requests.clear()
        self._active_pickers.clear()
        self._link_metadata_devices.clear()
        self._link_session_workspaces.clear()
        self._link_draft_messages.clear()
        self._link_active_drafts.clear()
        self._link_draft_sent_at.clear()
        self._mark_disconnected()

    async def send(
        self,
        chat_id: str,
        content: str,
        reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> SendResult:
        return await adapter_delivery.send(
            self, chat_id, content,
            reply_to, metadata, _channel_event=_channel_event,
            _is_link_chat_id=_is_link_chat_id, _text=_text, profile_display_name=profile_display_name,
        )

    async def _send_link_attachment(
        self,
        *,
        chat_id: str,
        path: str,
        caption: str | None,
        reply_to: str | None,
        metadata: Dict[str, Any] | None,
    ) -> SendResult:
        return await adapter_delivery._send_link_attachment(
            self, chat_id=chat_id, path=path,
            caption=caption, reply_to=reply_to, metadata=metadata,
            _is_link_chat_id=_is_link_chat_id,
        )

    async def send_image_file(
        self,
        chat_id: str,
        image_path: str,
        caption: Optional[str] = None,
        reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
        **kwargs,
    ) -> SendResult:
        del kwargs
        if self.link_client is None or not _is_link_chat_id(chat_id):
            return await super().send_image_file(
                chat_id=chat_id,
                image_path=image_path,
                caption=caption,
                reply_to=reply_to,
                metadata=metadata,
            )
        return await self._send_link_attachment(
            chat_id=chat_id,
            path=image_path,
            caption=caption,
            reply_to=reply_to,
            metadata=metadata,
        )

    async def send_image(
        self,
        chat_id: str,
        image_url: str,
        caption: Optional[str] = None,
        reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> SendResult:
        if self.link_client is None or not _is_link_chat_id(chat_id):
            return await super().send_image(
                chat_id=chat_id,
                image_url=image_url,
                caption=caption,
                reply_to=reply_to,
                metadata=metadata,
            )
        try:
            from gateway.platforms.base import cache_image_from_url
            import httpx
        except ImportError as exc:
            return SendResult(
                success=False,
                error=f"Loopdy remote image support is unavailable ({type(exc).__name__})",
            )
        try:
            image_path = await cache_image_from_url(image_url)
        except (OSError, ValueError, httpx.HTTPError) as exc:
            return SendResult(
                success=False,
                error=f"Loopdy remote image download failed ({type(exc).__name__})",
            )
        return await self._send_link_attachment(
            chat_id=chat_id,
            path=image_path,
            caption=caption,
            reply_to=reply_to,
            metadata=metadata,
        )

    async def send_document(
        self,
        chat_id: str,
        file_path: str,
        caption: Optional[str] = None,
        file_name: Optional[str] = None,
        reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
        **kwargs,
    ) -> SendResult:
        del kwargs
        if self.link_client is None or not _is_link_chat_id(chat_id):
            return await super().send_document(
                chat_id=chat_id,
                file_path=file_path,
                caption=caption,
                reply_to=reply_to,
                metadata=metadata,
            )
        return await self._send_link_attachment(
            chat_id=chat_id,
            path=file_path,
            caption=caption,
            reply_to=reply_to,
            metadata=metadata,
        )

    async def send_video(
        self,
        chat_id: str,
        video_path: str,
        caption: Optional[str] = None,
        reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
        **kwargs,
    ) -> SendResult:
        del kwargs
        if self.link_client is None or not _is_link_chat_id(chat_id):
            return await super().send_video(
                chat_id=chat_id,
                video_path=video_path,
                caption=caption,
                reply_to=reply_to,
                metadata=metadata,
            )
        return await self._send_link_attachment(
            chat_id=chat_id,
            path=video_path,
            caption=caption,
            reply_to=reply_to,
            metadata=metadata,
        )

    async def send_voice(
        self,
        chat_id: str,
        audio_path: str,
        caption: Optional[str] = None,
        reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
        **kwargs,
    ) -> SendResult:
        del kwargs
        if self.link_client is None or not _is_link_chat_id(chat_id):
            return await super().send_voice(
                chat_id=chat_id,
                audio_path=audio_path,
                caption=caption,
                reply_to=reply_to,
                metadata=metadata,
            )
        return await self._send_link_attachment(
            chat_id=chat_id,
            path=audio_path,
            caption=caption,
            reply_to=reply_to,
            metadata=metadata,
        )

    async def send_clarify(
        self,
        chat_id: str,
        question: str,
        choices: Optional[list],
        clarify_id: str,
        session_key: str,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> SendResult:
        return await adapter_delivery.send_clarify(
            self, chat_id, question,
            choices, clarify_id, session_key,
            metadata, _active_profile_id=_active_profile_id, _text=_text,
            logger=logger, profile_display_name=profile_display_name, base_send_clarify=super().send_clarify,
        )

    async def get_chat_info(self, chat_id: str) -> dict[str, str]:
        return {
            "name": "Loopdy chat" if _is_link_chat_id(chat_id) else str(chat_id),
            "type": "dm" if _is_link_chat_id(chat_id) else "notification",
        }

    def supports_draft_streaming(
        self,
        chat_type: str | None = None,
        metadata: Dict[str, Any] | None = None,
        chat_id: str | None = None,
    ) -> bool:
        return self.link_client is not None and (
            chat_id is None or _is_link_chat_id(chat_id)
        )

    async def send_draft(
        self,
        chat_id: str,
        draft_id: int,
        content: str,
        metadata: Dict[str, Any] | None = None,
    ) -> SendResult:
        return await adapter_delivery.send_draft(
            self, chat_id, draft_id,
            content, metadata, _LINK_DRAFT_MINIMUM_INTERVAL_SECONDS=_LINK_DRAFT_MINIMUM_INTERVAL_SECONDS,
            _is_link_chat_id=_is_link_chat_id, _text=_text, profile_display_name=profile_display_name,
        )

    @staticmethod
    def _new_message_id() -> str:
        return "message_" + encode_base64url(os.urandom(18))

    @staticmethod
    def _link_draft_turn_key(
        chat_id: str, metadata: Dict[str, Any]
    ) -> tuple[str, str]:
        return adapter_delivery._link_draft_turn_key(chat_id, metadata, _text=_text)

    def _active_link_draft(
        self, chat_id: str, metadata: Dict[str, Any]
    ) -> tuple[tuple[str, int], str] | None:
        return adapter_delivery._active_link_draft(self, chat_id, metadata)

    def _finish_link_draft(
        self,
        chat_id: str,
        metadata: Dict[str, Any],
        draft_key: tuple[str, int],
    ) -> None:
        return adapter_delivery._finish_link_draft(self, chat_id, metadata, draft_key)

    def _trim_link_draft_identities(self) -> None:
        return adapter_delivery._trim_link_draft_identities(
            self, _MAX_LINK_DRAFT_IDENTITIES=_MAX_LINK_DRAFT_IDENTITIES,
        )

    async def send_model_picker(
        self,
        chat_id: str,
        providers: list,
        current_model: str,
        current_provider: str,
        session_key: str,
        on_model_selected,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> SendResult:
        return await adapter_pickers.send_model_picker(
            self, chat_id, providers,
            current_model, current_provider, session_key,
            on_model_selected, metadata, _ActivePicker=_ActivePicker,
            _picker_request_id=_picker_request_id,
        )

    async def send_choice_picker(
        self,
        chat_id: str,
        title: str,
        choices: list,
        session_key: str,
        on_choice_selected,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> SendResult:
        return await adapter_pickers.send_choice_picker(
            self, chat_id, title,
            choices, session_key, on_choice_selected,
            metadata, _ActivePicker=_ActivePicker, _picker_request_id=_picker_request_id,
        )

    async def receive_link_turn(self, turn: InboundLinkTurn) -> None:
        route = current_reply_route.get()
        # Synthetic/legacy clients without a paired config keep ordinary behavior.
        if route is None and getattr(self.link_client, "config", None) is not None:
            route = self._link_reply_route(turn.sender_device_id, turn.sender_epoch or 0)
        if route is None:
            await self._dispatch_link_turn(turn)
            return
        route.check_current()
        lease = self._turn_replies.register(turn.message.agent_id, turn.message.session_id,
                                             turn.message.message_id, route)
        route_token = current_reply_route.set(route)
        lease_token = current_turn_lease.set(lease)
        try:
            await self._dispatch_link_turn(turn)
        except BaseException:
            self._turn_replies.complete(lease)
            raise
        finally:
            current_turn_lease.reset(lease_token)
            current_reply_route.reset(route_token)

    async def _dispatch_link_turn(self, turn: InboundLinkTurn) -> None:
        self._remember_verified_link_profile(
            turn.message.session_id,
            turn.message.agent_id,
        )
        source = self.build_source(
            chat_id=turn.message.session_id,
            chat_name="Loopdy chat",
            chat_type="dm",
            user_id=turn.sender_id,
            user_name=turn.message.actor_name,
            message_id=turn.message.message_id,
        )
        source.profile = turn.message.agent_id
        execution_context = _verified_tool_execution_context(self.link_client, turn)
        event = MessageEvent(
            text=turn.message.text,
            source=source,
            message_id=turn.message.message_id,
            media_urls=list(turn.attachment_paths),
            media_types=list(turn.attachment_types),
            metadata={
                "loopdy_link_verified": True,
                **(
                    {"loopdy_link_behavior": turn.message.behavior}
                    if turn.message.behavior is not None
                    else {}
                ),
            },
            **(
                {"tool_execution_context": execution_context}
                if execution_context is not None else {}
            ),
        )
        await self._materialize_pending_link_session_workspace(
            turn.message.agent_id,
            turn.message.session_id,
            source,
        )
        behavior = turn.message.behavior
        has_pending_intercept = self._has_pending_link_intercept(source)
        if not has_pending_intercept and event.get_command() in {"steer", "queue"}:
            await self._dispatch_link_control(event)
            await self._refresh_goal_for_source(source)
            return
        if (
            behavior is None
            or has_pending_intercept
            or self._has_registered_command(event.text)
        ):
            await self.handle_message(event)
            # Safe/bypass slash commands need not enter background processing,
            # so they do not necessarily reach on_processing_complete.
            await self._refresh_goal_for_source(source)
            return

        if behavior == "steer" and (event.media_urls or event.media_types):
            # Hermes' official /steer control carries text only. Preserve Link
            # attachments by using Hermes' official FIFO /queue fallback.
            behavior = "queue"

        if behavior in {"steer", "queue"}:
            event.text = f"/{behavior} {event.text}"
            busy = {"task": asyncio.current_task(), "chat_id": source.chat_id,
                    "message_id": event.message_id, "response": None}
            token = self._busy_response.set(busy)
            try:
                await self._dispatch_link_control(event)
            finally:
                self._busy_response.reset(token)
            # Inline control requests do not reach processing_complete. An idle
            # request starts a distinct task and has no captured inline reply.
            lease = current_turn_lease.get()
            if behavior == "steer" and busy["response"] is not None and lease is not None:
                self._turn_replies.complete(lease)
            return

        session_key = self._link_session_key(source)
        if session_key in self._active_sessions:
            self._heal_stale_session_lock(session_key)
        if session_key not in self._active_sessions:
            # An idle session has nothing to interrupt. Submit the original
            # event normally so first-turn semantics and attachments stay
            # byte-for-byte equivalent to an ordinary Link send.
            await self.handle_message(event)
            return

        stop_event = MessageEvent(
            text="/stop",
            source=source,
            metadata={
                "loopdy_link_verified": True,
                "loopdy_link_behavior": "interrupt",
                "loopdy_link_control": True,
            },
        )
        token = _suppress_link_control_ephemeral.set(True)
        control = self._control_response_task.set(asyncio.current_task())
        try:
            # BasePlatformAdapter's interrupt_then_dispatch path does not
            # return until Hermes has handled /stop, cancelled the old owner,
            # released its command guard, and drained any pending handoff.
            await self.handle_message(stop_event)
        finally:
            self._control_response_task.reset(control)
            _suppress_link_control_ephemeral.reset(token)
        await self.handle_message(event)

    async def on_processing_start(self, event: MessageEvent) -> None:
        lease = self._turn_replies.lookup(
            getattr(event.source, "profile", None) or _active_profile_id(),
            event.source.chat_id, event.message_id)
        # Queued work may inherit a previous task's context; bind the event's
        # exact registered owner before any processing callbacks can send.
        current_turn_lease.set(lease)
        picker_id = (event.metadata or {}).get("loopdy_picker_control")
        pending_picker = self._pending_picker_requests.get(picker_id or "")
        current_reply_route.set(lease.route if lease else
                                pending_picker.route if pending_picker else None)
        if pending_picker is not None:
            self._control_response_task.set(asyncio.current_task())
        if lease is not None:
            lease.route.check_current()
            self._processing_turns.add(lease.generation)
        self._observe_presentation("processing_start", event=event, lease=lease)
        await super().on_processing_start(event)
    async def _dispatch_link_control(self, event: MessageEvent) -> None:
        with capture_control_replies(
            self,
            event.source.chat_id,
            event.get_command(),
            event.get_command_args().strip(),
        ):
            await self.handle_message(event)

    async def on_processing_complete(
        self,
        event: MessageEvent,
        outcome: ProcessingOutcome,
    ) -> None:
        try:
            await super().on_processing_complete(event, outcome)
        finally:
            # BasePlatformAdapter.handle_message() returns after scheduling
            # Hermes' background work. Link media must therefore outlive the
            # inbound callback and remain readable until this authoritative
            # processing-complete lifecycle hook runs.
            if (event.metadata or {}).get("loopdy_link_verified"):
                release = getattr(self.link_client, "release_attachment_paths", None)
                if callable(release) and event.media_urls:
                    release(tuple(event.media_urls))
            lease = self._turn_replies.lookup(
                getattr(event.source, "profile", None) or _active_profile_id(),
                event.source.chat_id, event.message_id)
            self._observe_presentation("processing_complete", event=event, outcome=outcome, lease=lease)
            if lease is not None:
                self._processing_turns.discard(lease.generation)
                self._turn_replies.complete(lease)
            # Runs after the goal judge. The text/outcome are never verdicts.
            # Release attachments first even if this readback is cancelled.
            if event.source is not None:
                await self._refresh_goal_for_source(event.source)

    def _link_session_key(self, source: SessionSource) -> str:
        return adapter_sessions._link_session_key(self, source)

    def _is_link_session_active(
        self,
        agent_id: str,
        session_id: str,
        _stored_id: str,
    ) -> bool:
        return adapter_sessions._is_link_session_active(self, agent_id, session_id, _stored_id)

    def _has_pending_link_intercept(self, source: SessionSource) -> bool:
        """Keep Hermes approval/clarification replies on the normal text path."""
        session_key = self._link_session_key(source)
        try:
            from tools.approval import has_blocking_approval

            if has_blocking_approval(session_key):
                return True
        except Exception:
            # Fail safe: a behavior prefix would prevent Hermes' normal
            # plaintext approval routing from seeing the reply.
            return True
        try:
            from tools.clarify_gateway import get_pending_for_session

            return (
                get_pending_for_session(
                    session_key,
                    include_choice_prompts=True,
                )
                is not None
            )
        except Exception:
            # Fail safe for the same reason: never hide a possible clarify
            # response behind /steer or /queue when inspection is unavailable.
            return True

    @staticmethod
    def _has_registered_command(text: str) -> bool:
        """Let Hermes own every registered command's active-turn behavior."""
        token = text.split(None, 1)[0] if text else ""
        if not token.startswith("/"):
            return False
        try:
            from hermes_cli.commands import should_bypass_active_session

            return should_bypass_active_session(token[1:].lower())
        except Exception:
            return False

    def _unwrap_ephemeral(self, response: Any) -> tuple[Optional[str], int]:
        if _suppress_link_control_ephemeral.get() and isinstance(
            response, EphemeralReply
        ):
            return None, 0
        return super()._unwrap_ephemeral(response)

    def _remember_verified_link_profile(self, session_id: str, profile: str) -> None:
        return adapter_sessions._remember_verified_link_profile(
            self, session_id, profile,
            _MAX_LINK_SESSION_PROFILE_BINDINGS=_MAX_LINK_SESSION_PROFILE_BINDINGS, _is_link_chat_id=_is_link_chat_id, _profile_coordinate=_profile_coordinate,
        )

    async def _set_link_session_workspace(
        self,
        agent_id: str,
        session_id: str,
        cwd: str,
    ) -> None:
        return await adapter_sessions._set_link_session_workspace(
            self, agent_id, session_id,
            cwd, _MAX_LINK_SESSION_PROFILE_BINDINGS=_MAX_LINK_SESSION_PROFILE_BINDINGS,
        )

    async def _materialize_pending_link_session_workspace(
        self,
        agent_id: str,
        session_id: str,
        source: SessionSource,
    ) -> None:
        return await adapter_sessions._materialize_pending_link_session_workspace(
            self, agent_id, session_id,
            source,
        )

    def _link_workspace_connection_id(self) -> str:
        """Return the authenticated Link sender for the current request only."""

        connection_id = _link_workspace_connection.get()
        if not connection_id:
            raise RuntimeError("Loopdy Link connection identity is unavailable")
        return connection_id

    async def _get_link_session_workspace(
        self,
        agent_id: str,
        session_id: str,
    ) -> str | None:
        return await adapter_sessions._get_link_session_workspace(self, agent_id, session_id)

    def _link_response_profile(
        self,
        session_id: str,
        metadata: Dict[str, Any],
    ) -> str:
        return adapter_sessions._link_response_profile(
            self, session_id, metadata,
            _active_profile_id=_active_profile_id, _profile_coordinate=_profile_coordinate,
        )

    async def _workspace_history_context(
        self, request: WorkspaceRequest, result: dict[str, Any]
    ) -> dict[str, Any] | None:
        return await adapter_sessions._workspace_history_context(self, request, result)

    async def receive_link_payload(self, payload) -> None:
        if (not isinstance(payload, InboundLinkDirectEnrollment)
                and current_reply_route.get() is None
                and getattr(self.link_client, "config", None) is not None):
            route = self._link_reply_route(payload.sender_device_id,
                                           getattr(payload, "sender_epoch", None) or 0)
            token = current_reply_route.set(route)
            try:
                await self._dispatch_inbound_payload(payload)
            finally:
                current_reply_route.reset(token)
        else:
            await self._dispatch_inbound_payload(payload)

    async def _dispatch_inbound_payload(
        self,
        payload: (
            InboundLinkDirectEnrollment
            | InboundLinkTurn
            | InboundLinkRelayReady
            | InboundLinkVoiceSpeak
            | InboundLinkPickerOpen
            | InboundLinkPickerSelection
            | InboundLinkSessionFork
            | InboundLinkCommandCatalog
            | InboundLinkPersonalityRequest
            | InboundLinkGenerativeUIFormSubmission
            | InboundLinkWorkspaceRequest
            | InboundLinkDeviceToolResult
            | InboundLinkDeviceToolStatus
        ),
    ) -> None:
        # Preserve ordered isinstance routing, including injected subclasses.
        if isinstance(payload, InboundLinkDirectEnrollment):
            return await adapter_requests.receive_direct_enrollment(self, payload)
        if isinstance(payload, InboundLinkWorkspaceRequest):
            return await adapter_requests.receive_workspace_request(
                self, payload, _MAX_LINK_METADATA_DEVICES=_MAX_LINK_METADATA_DEVICES, _link_workspace_connection=_link_workspace_connection)
        handlers = (
            (InboundLinkDeviceToolStatus, adapter_requests.receive_device_tool_status),
            (InboundLinkDeviceToolResult, adapter_requests.receive_device_tool_result),
            (InboundLinkGenerativeUIFormSubmission, adapter_requests.receive_form_submission),
            (InboundLinkPersonalityRequest, adapter_requests.receive_personality_request),
            (InboundLinkCommandCatalog, adapter_requests.receive_command_catalog),
            (InboundLinkSessionFork, adapter_requests.receive_session_fork),
            (InboundLinkPickerOpen, adapter_pickers.receive_picker_open),
            (InboundLinkPickerSelection, adapter_pickers.receive_picker_selection),
            (InboundLinkVoiceSpeak, adapter_requests.receive_voice_request),
        )
        for payload_type, handler in handlers:
            if isinstance(payload, payload_type):
                return await handler(self, payload)
        if isinstance(payload, InboundLinkRelayReady):
            # Retired relay readiness cannot affect chat or notification enrollment.
            return
        await self.receive_link_turn(payload)

    def _submit_generative_ui_form(self, request: Any) -> dict[str, Any]:
        return adapter_requests._submit_generative_ui_form(self, request)

    async def _build_link_command_catalog(
        self, request: CommandCatalogRequest
    ) -> list[dict[str, Any]]:
        return await adapter_requests._build_link_command_catalog(self, request)

    async def _fork_link_session(
        self, inbound: InboundLinkSessionFork
    ) -> dict[str, Any]:
        return await adapter_requests._fork_link_session(self, inbound)

    async def _receive_picker_open(self, inbound: InboundLinkPickerOpen) -> None:
        return await adapter_pickers._receive_picker_open(
            self, inbound, MessageEvent=MessageEvent,
            _PendingPickerRequest=_PendingPickerRequest, _picker_request_id=_picker_request_id,
        )

    async def _send_picker_open_failure(
        self, request: PickerOpen, message: str
    ) -> None:
        return await adapter_pickers._send_picker_open_failure(self, request, message)

    async def _receive_picker_selection(
        self, inbound: InboundLinkPickerSelection
    ) -> None:
        return await adapter_pickers._receive_picker_selection(self, inbound)

    async def _send_picker_result(
        self,
        *,
        selection: PickerSelection,
        status: str,
        message: str,
    ) -> None:
        return await adapter_pickers._send_picker_result(self, selection=selection, status=status, message=message)

    def _take_pending_picker(
        self, request_id: str, session_id: str, kind: str
    ) -> _PendingPickerRequest | None:
        return adapter_pickers._take_pending_picker(self, request_id, session_id, kind)

    def _remember_picker(self, state: _ActivePicker) -> None:
        return adapter_pickers._remember_picker(self, state)

    def _clean_picker_state(self) -> None:
        return adapter_pickers._clean_picker_state(self)

    async def _serve_voice_request(self, request: VoiceSpeakRequest) -> None:
        return await adapter_voice._serve_voice_request(self, request)


async def standalone_send(
    pconfig: PlatformConfig,
    chat_id: str,
    message: str,
    *,
    thread_id: str | None = None,
    media_files: list[str] | None = None,
    force_document: bool = False,
    service: LoopdyService | Any | None = None,
    link_state: Any | None = None,
    adapter_factory: Callable[..., LoopdyAdapter | Any] = LoopdyAdapter,
) -> dict[str, Any]:
    if media_files:
        return {"error": "Loopdy proactive notifications do not accept attachments"}
    del force_document
    target = str(
        chat_id
        or (getattr(pconfig, "extra", {}) or {}).get("home_target")
        or os.getenv("LOOPDY_HOME_TARGET", "all")
    ).strip()
    adapter = adapter_factory(
        pconfig,
        service=service or get_service(),
        link_state=link_state,
    )
    try:
        if not await adapter.connect():
            return {"error": "Loopdy Link is unavailable"}
        result = await adapter.send(
            target,
            message,
            metadata={"thread_id": thread_id} if thread_id else None,
        )
        if result.success:
            return {
                "success": True,
                "message_id": str(result.message_id or ""),
            }
        return {"error": str(result.error or "Loopdy delivery failed")}
    finally:
        await adapter.disconnect()


def check_requirements() -> bool:
    return True


def validate_config(_config: PlatformConfig) -> bool:
    try:
        link_ready = load_runtime_config() is not None
    except ValueError:
        link_ready = False
    return bool(link_ready or get_service().health().get("configured"))


def is_connected(config: PlatformConfig) -> bool:
    return bool(config.enabled and validate_config(config))


def env_enablement() -> dict[str, Any] | None:
    service = get_service()
    try:
        link_ready = load_runtime_config() is not None
    except ValueError:
        link_ready = False
    if not service.health().get("configured") and not link_ready:
        return None
    target = os.getenv("LOOPDY_HOME_TARGET", "all").strip() or "all"
    if validate_target(target) is not True:
        return None
    return {
        "home_target": target,
        "home_channel": {"chat_id": target, "name": "Loopdy"},
    }


def _is_link_chat_id(value: str) -> bool:
    chat_id = str(value or "")
    return (
        16 <= len(chat_id) <= 128
        and all(character.isalnum() or character in "_-" for character in chat_id)
        and chat_id not in {"all", "home"}
    )


def _channel_event(
    content: str, *, metadata: Optional[Dict[str, Any]], target: str = "all"
) -> Any:
    values = metadata or {}
    requested_type = str(values.get("event_type") or "")
    job_id = _text(values.get("job_id"), 180)
    kind = requested_type if requested_type in EVENT_TYPES else "channel.message"
    profile = (
        _text(values.get("profile") or values.get("profile_name"), 80)
        or _active_profile_id()
    )
    agent_name = _text(values.get("agent_name") or values.get("sender_name"), 80)
    if not agent_name:
        agent_name = profile_display_name(profile)
    message = _text(content, 50_000)
    detail: dict[str, Any] = {
        "message": message,
        **({"agent_name": agent_name} if agent_name else {}),
    }
    correlation: tuple[str, ...] = ()
    card_content = _channel_card_content(content, job_id=job_id)
    if card_content is not None:
        try:
            card = validate_rendered_envelope(parse_v2_json(card_content))
            detail["message"] = _text(card.get("title"), 120) or "Agent update"
            detail["generative_ui"] = card
            # Standalone cron fallback drops job metadata. Use the complete
            # validated card instance, including creation time, so both paths
            # retain one Inbox identity without hiding later identical updates.
            correlation = (
                "card-instance-v1", profile, target,
                json.dumps(card, sort_keys=True, separators=(",", ":"), ensure_ascii=True),
            )
        except (GenerativeUIError, TypeError, ValueError):
            pass
    return build_event(
        kind,
        correlation=correlation,
        profile=profile,
        session_id=_text(values.get("session_id"), 180),
        job_id=job_id,
        detail=detail,
    )


def _channel_card_content(content: Any, *, job_id: str) -> str | None:
    """Return only a complete renderer envelope from an official send boundary.

    Hermes platform adapters receive final text, not tool-result metadata. Cron
    normally wraps that final text with its stable response header/footer and
    supplies the matching ``job_id`` in adapter metadata. Unwrap only that
    authenticated-by-correlation shape; renderer validation remains the final
    authority and every other value falls back to ordinary text.
    """
    if not isinstance(content, str):
        return None
    stripped = content.strip()
    if stripped.startswith("{"):
        return stripped
    if not job_id or not content.startswith("Cronjob Response: "):
        return None
    boundary = f"\n(job_id: {job_id})\n-------------\n\n"
    prefix, found, remainder = content.partition(boundary)
    if not found or not prefix.startswith("Cronjob Response: "):
        return None
    payload, footer, _ = remainder.partition(
        "\n\nTo stop or manage this job, send me a new message "
    )
    if not footer:
        return None
    candidate = payload.strip()
    return candidate if candidate.startswith("{") else None


def _active_profile_id() -> str:
    home = get_hermes_home()
    return home.name if home.parent.name == "profiles" else "default"


def profile_display_name(profile: str) -> str:
    home = get_hermes_home()
    if home.parent.name == "profiles" and home.name != profile:
        root = home.parent.parent
        home = root if profile == "default" else root / "profiles" / profile
    elif home.parent.name != "profiles" and profile != "default":
        home = home / "profiles" / profile
    try:
        import yaml

        value = (
            yaml.safe_load((home / "profile.yaml").read_text(encoding="utf-8"))
            or {}
        )
        ui_meta = value.get("ui_meta") if isinstance(value, dict) else {}
        display_name = (
            ui_meta.get("displayName")
            if isinstance(ui_meta, dict)
            else None
        ) or (value.get("display_name") if isinstance(value, dict) else None)
        resolved = _text(display_name, 80)
        if resolved:
            return resolved
    except Exception:
        pass
    return " ".join(
        part.capitalize()
        for part in profile.replace("-", "_").split("_")
        if part
    )


def _text(value: Any, maximum: int) -> str:
    return " ".join(value.split())[:maximum] if isinstance(value, str) else ""


def _profile_coordinate(value: Any) -> str:
    profile = str(value or "").strip()
    if not 1 <= len(profile) <= 96 or any(
        not (character.isalnum() or character in "_-") for character in profile
    ):
        return ""
    return profile


__all__ = [
    "LoopdyAdapter",
    "profile_display_name",
    "check_requirements",
    "env_enablement",
    "get_service",
    "is_connected",
    "parse_target",
    "release_service",
    "standalone_send",
    "validate_config",
    "validate_target",
]
