"""Request-bound model/reasoning pickers and authenticated selections.

Operations use the calling LoopdyAdapter as their sole state/lifecycle owner.
Facade-owned callables and context variables are explicit call-time dependencies.
"""

from __future__ import annotations

import asyncio
import inspect
import time
from dataclasses import dataclass
from typing import Any, Dict, Optional
from gateway.platforms.base import MessageEvent, SendResult
from .inbound_dispatch import ReplyRoute, current_reply_route
from .link_client import InboundLinkPickerOpen, InboundLinkPickerSelection
from .link_contracts import (
    PickerOpen,
    PickerSelection,
    choice_picker_payload,
    model_picker_payload,
    picker_result,
)


@dataclass(frozen=True)
class _ActivePicker:
    picker_id: str
    session_id: str
    kind: str
    sender_device_id: str
    callback: Any
    allowed_models: frozenset[tuple[str, str]]
    allowed_values: frozenset[str]
    expires_at: float
    route: ReplyRoute | None = None


@dataclass(frozen=True)
class _PendingPickerRequest:
    request: PickerOpen
    sender_device_id: str
    expires_at: float
    route: ReplyRoute | None = None
    ready: Any = None


async def send_model_picker(
    self,
    chat_id: str,
    providers: list,
    current_model: str,
    current_provider: str,
    session_key: str,
    on_model_selected,
    metadata: Optional[Dict[str, Any]] = None, *, _ActivePicker, _picker_request_id) -> SendResult:
    del session_key, metadata
    if self.link_client is None:
        return SendResult(success=False, error="Loopdy Link is not connected")
    pending = self._take_pending_picker(
        request_id=_picker_request_id.get(),
        session_id=str(chat_id),
        kind="model",
    )
    if pending is None:
        return SendResult(success=False, error="No active Loopdy model request")
    try:
        payload = model_picker_payload(
            picker_id=pending.request.request_id,
            session_id=pending.request.session_id,
            current_model=current_model,
            current_provider=current_provider,
            providers=providers,
            sent_at=int(time.time()),
        )
        allowed = frozenset(
            (row["id"], model)
            for row in payload["providers"]
            for model in row["models"]
        )
        self._remember_picker(
            _ActivePicker(
                picker_id=pending.request.request_id,
                session_id=pending.request.session_id,
                kind="model",
                sender_device_id=pending.sender_device_id,
                callback=on_model_selected,
                allowed_models=allowed,
                allowed_values=frozenset(),
                expires_at=time.monotonic() + 600,
                route=pending.route,
            )
        )
        await self._send_link_payload(payload, reply_route=pending.route)
        if pending.ready is not None and not pending.ready.done():
            pending.ready.set_result(True)
        return SendResult(success=True, message_id=pending.request.request_id)
    except Exception as exc:
        self._active_pickers.pop(pending.request.request_id, None)
        await self._send_picker_open_failure(
            pending.request,
            "Hermes could not open this model picker. Try again.",
        )
        return SendResult(
            success=False,
            error=f"Loopdy model picker failed ({type(exc).__name__})",
        )


async def send_choice_picker(
    self,
    chat_id: str,
    title: str,
    choices: list,
    session_key: str,
    on_choice_selected,
    metadata: Optional[Dict[str, Any]] = None, *, _ActivePicker, _picker_request_id) -> SendResult:
    del session_key, metadata
    if self.link_client is None:
        return SendResult(success=False, error="Loopdy Link is not connected")
    pending = self._take_pending_picker(
        request_id=_picker_request_id.get(),
        session_id=str(chat_id),
        kind="reasoning",
    )
    if pending is None:
        return SendResult(success=False, error="No active Loopdy reasoning request")
    try:
        payload = choice_picker_payload(
            picker_id=pending.request.request_id,
            session_id=pending.request.session_id,
            title=title,
            choices=choices,
            sent_at=int(time.time()),
        )
        self._remember_picker(
            _ActivePicker(
                picker_id=pending.request.request_id,
                session_id=pending.request.session_id,
                kind="reasoning",
                sender_device_id=pending.sender_device_id,
                callback=on_choice_selected,
                allowed_models=frozenset(),
                allowed_values=frozenset(row["value"] for row in payload["choices"]),
                expires_at=time.monotonic() + 600,
                route=pending.route,
            )
        )
        await self._send_link_payload(payload, reply_route=pending.route)
        if pending.ready is not None and not pending.ready.done():
            pending.ready.set_result(True)
        return SendResult(success=True, message_id=pending.request.request_id)
    except Exception as exc:
        self._active_pickers.pop(pending.request.request_id, None)
        await self._send_picker_open_failure(
            pending.request,
            "Hermes could not open this reasoning picker. Try again.",
        )
        return SendResult(
            success=False,
            error=f"Loopdy reasoning picker failed ({type(exc).__name__})",
        )


async def _receive_picker_open(
    self, inbound: InboundLinkPickerOpen, *, MessageEvent, _PendingPickerRequest,
    _picker_request_id,
) -> None:
    self._clean_picker_state()
    request = inbound.request
    if request.request_id in self._pending_picker_requests or request.request_id in self._active_pickers:
        raise ValueError("picker request identity already in use")
    route = current_reply_route.get()
    ready = asyncio.get_running_loop().create_future()
    self._pending_picker_requests[request.request_id] = _PendingPickerRequest(
        request=request, sender_device_id=inbound.sender_device_id,
        expires_at=time.monotonic() + 60, route=route, ready=ready)
    self._remember_verified_link_profile(request.session_id, request.agent_id)
    source = self.build_source(
        chat_id=request.session_id,
        chat_name="Loopdy chat",
        chat_type="dm",
        user_id="loopdy_link_control",
        user_name="Loopdy user",
        message_id=request.request_id,
    )
    source.profile = request.agent_id
    # Use the supported ordinary message entry point. Only this plugin
    # control event's textual fallback is suppressed, never another turn.
    event = MessageEvent(
        text="/model" if request.kind == "model" else "/reasoning",
        source=source,
        message_id=request.request_id,
        metadata={
            "loopdy_link_verified": True,
            "loopdy_link_control": True,
            "loopdy_picker_control": request.request_id,
        },
    )
    try:
        token = _picker_request_id.set(request.request_id)
        control = self._control_response_task.set(asyncio.current_task())
        try:
            await self.handle_message(event)
            await asyncio.wait_for(asyncio.shield(ready), timeout=10)
        finally:
            self._control_response_task.reset(control)
            _picker_request_id.reset(token)
    except Exception:
        # The native picker is best effort.  Its control response must
        # never become a normal assistant message or interrupt a chat.
        self._pending_picker_requests.pop(request.request_id, None)
        await self._send_picker_open_failure(
            request,
            "Hermes could not open this picker. Try again.",
        )
        return
    if self._pending_picker_requests.pop(request.request_id, None) is not None:
        await self._send_picker_open_failure(
            request,
            "Hermes completed this request without opening a native picker. Try again.",
        )


async def _send_picker_open_failure(
    self, request: PickerOpen, message: str
) -> None:
    """Complete a failed picker-open request on the same control channel."""
    if self.link_client is None:
        return
    try:
        await self._send_link_payload(
            picker_result(
                picker_id=request.request_id,
                session_id=request.session_id,
                kind=request.kind,
                status="failed",
                message=message,
                sent_at=int(time.time()),
            )
        )
    except Exception:
        return


async def _receive_picker_selection(
    self, inbound: InboundLinkPickerSelection
) -> None:
    self._clean_picker_state()
    selection = inbound.selection
    state = self._active_pickers.get(selection.picker_id)
    selection_route = current_reply_route.get()
    valid = bool(
        state is not None
        and state.session_id == selection.session_id
        and state.kind == selection.kind
        and state.sender_device_id == inbound.sender_device_id
        and (state.route is None or (
            selection_route is not None
            and selection_route.owner == state.route.owner))
        and (
            (selection.provider, selection.model) in state.allowed_models
            if selection.kind == "model"
            else selection.value in state.allowed_values
        )
    )
    if not valid or state is None:
        await self._send_picker_result(
            selection=selection,
            status="failed",
            message="This control is no longer available. Open it again to continue.",
        )
        return
    self._active_pickers.pop(selection.picker_id, None)
    try:
        if state.route is not None:
            state.route.check_current()
        if selection.kind == "model":
            result = state.callback(
                selection.session_id, selection.model, selection.provider
            )
        else:
            result = state.callback(selection.session_id, selection.value)
        if inspect.isawaitable(result):
            result = await result
        message = str(result or "Updated for this session.")
        status = "completed"
    except Exception:
        message = "Hermes could not update this session. Open the control and try again."
        status = "failed"
    await self._send_picker_result(
        selection=selection,
        status=status,
        message=message,
    )


async def _send_picker_result(
    self,
    *,
    selection: PickerSelection,
    status: str,
    message: str,
) -> None:
    if self.link_client is None:
        return
    try:
        await self._send_link_payload(
            picker_result(
                picker_id=selection.picker_id,
                session_id=selection.session_id,
                kind=selection.kind,
                status=status,
                message=message[:2_000] or "The control could not be updated.",
                sent_at=int(time.time()),
            )
        )
    except Exception:
        return


def _take_pending_picker(
    self, request_id: str, session_id: str, kind: str
) -> _PendingPickerRequest | None:
    self._clean_picker_state()
    if not request_id:
        return None
    pending = self._pending_picker_requests.get(request_id)
    if pending is None:
        return None
    if pending.request.session_id != session_id or pending.request.kind != kind:
        return None
    return self._pending_picker_requests.pop(request_id, None)


def _remember_picker(self, state: _ActivePicker) -> None:
    self._clean_picker_state()
    if len(self._active_pickers) >= 64:
        oldest = min(self._active_pickers.values(), key=lambda item: item.expires_at)
        self._active_pickers.pop(oldest.picker_id, None)
    self._active_pickers[state.picker_id] = state


def _clean_picker_state(self) -> None:
    now = time.monotonic()
    self._pending_picker_requests = {
        key: value
        for key, value in self._pending_picker_requests.items()
        if value.expires_at > now
    }
    self._active_pickers = {
        key: value
        for key, value in self._active_pickers.items()
        if value.expires_at > now
    }


async def receive_picker_open(self, payload):
    await self._receive_picker_open(payload)


async def receive_picker_selection(self, payload):
    await self._receive_picker_selection(payload)
