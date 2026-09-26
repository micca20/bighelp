"""Hermes session readback, verified profile bindings, and project cwd.

Operations use the calling LoopdyAdapter as their sole state/lifecycle owner.
Facade-owned callables and context variables are explicit call-time dependencies.
"""

from __future__ import annotations

import asyncio
import json
import time
from typing import Any, Dict
from gateway.session import SessionSource, build_session_key
from .link_contracts import WorkspaceRequest, _session_coordinate, session_context


def _goal_state_snapshot(self, session_id: str, *, _is_link_chat_id) -> dict[str, Any] | None:
    """Read Hermes' documented goal:<session_id> metadata, without mutation.

    load_goal() intentionally collapses storage failures into None. That
    convenience API is unsuitable for reconciliation: only a successful
    absent-row read is authoritative absence. Read the same public
    SessionDB metadata through the owning gateway profile instead.
    """
    store = getattr(self, "_session_store", None)
    lookup = getattr(store, "lookup_by_session_id", None)
    db_for_session = getattr(store, "_db_for_session_id", None)
    if not callable(lookup) or not callable(db_for_session):
        return None
    entry = lookup(session_id)
    origin = getattr(entry, "origin", None)
    if (
        getattr(entry, "session_id", None) != session_id
        or getattr(getattr(entry, "platform", None), "value", None) != "loopdy"
        or getattr(getattr(origin, "platform", None), "value", None) != "loopdy"
    ):
        return None
    route = getattr(origin, "chat_id", None)
    if not isinstance(route, str) or not _is_link_chat_id(route):
        return None
    db = db_for_session(session_id)
    get_meta = getattr(db, "get_meta", None)
    if not callable(get_meta):
        return None
    raw = get_meta(f"goal:{session_id}")
    if raw is None:
        status, summary = "none", None
    else:
        # Reject malformed/unknown state rather than erasing a valid rail.
        # Hermes' raw status is done (not a tool/turn's completed flag).
        if not isinstance(raw, (str, bytes, bytearray)):
            return None
        state = json.loads(raw)
        if not isinstance(state, dict):
            return None
        status = state.get("status")
        if not isinstance(status, str) or status not in {"active", "paused", "done", "cleared"}:
            return None
        summary = state.get("goal") if status in {"active", "paused"} else None
        if status in {"active", "paused"} and (
            not isinstance(summary, str) or not summary.strip()
        ):
            return None
    # Compression/reset may replace the route while the DB read is in
    # flight. Do not stamp the former owner's state as a fresh snapshot.
    current = lookup(session_id)
    if (
        getattr(current, "session_id", None) != session_id
        or getattr(getattr(current, "origin", None), "chat_id", None) != route
    ):
        return None
    return {
        "sessionId": route, "storedSessionId": session_id,
        "status": status, "summary": summary,
    }


async def runtime_snapshot_for_session(
    self, agent_id: str, stored_id: str,
) -> dict[str, str] | None:
    """Read an exact current session override through the public session store."""
    store = getattr(self, "_session_store", None)
    if store is None:
        return None

    def read():
        entry = store.lookup_by_session_id(stored_id)
        if entry is None or (getattr(entry.origin, "profile", None) or "default") != agent_id:
            return None
        key = entry.session_key
        override = store.get_model_override(key)
        if store.peek_session_id(key) != stored_id or not override:
            return None
        return {key: override[key] for key in ("model", "provider") if override.get(key)}

    return await asyncio.to_thread(read)


async def goal_snapshot_for_session(
    self, agent_id: str, session_id: str, stored_id: str, *, logger) -> dict[str, Any] | None:
    """Catalog/history readback seam for an already authorized session row.

    The workspace owner calls this with the resolved profile, visible
    route and exact stored id. Mismatched/retired rows are unavailable,
    never aliased onto the current conversation's goal.
    """
    store = getattr(self, "_session_store", None)
    lookup = getattr(store, "lookup_by_session_key", None)
    snapshot = getattr(self.activity_broker, "goal_snapshot", None)
    bind = getattr(self.activity_broker, "bind_link_session", None)
    if not callable(lookup) or not callable(snapshot) or not callable(bind):
        return None
    source = self.build_source(chat_id=session_id, chat_type="dm")
    source.profile = agent_id
    try:
        entry = await asyncio.to_thread(lookup, self._link_session_key(source))
        if getattr(entry, "session_id", None) != stored_id:
            return None
        bind(stored_id, session_id)
        result = await asyncio.to_thread(snapshot, stored_id)
        return result if isinstance(result, dict) else None
    except Exception as exc:
        logger.warning("Loopdy goal readback failed (%s)", type(exc).__name__)
        return None


async def _refresh_goal_for_source(self, source: SessionSource, *, logger) -> None:
    store = getattr(self, "_session_store", None)
    lookup = getattr(store, "lookup_by_session_key", None)
    publish = getattr(self.activity_broker, "publish_goal_snapshot", None)
    bind = getattr(self.activity_broker, "bind_link_session", None)
    if not callable(lookup) or not callable(publish) or not callable(bind):
        return
    try:
        entry = await asyncio.to_thread(lookup, self._link_session_key(source))
        session_id = getattr(entry, "session_id", None)
        if session_id:
            bind(session_id, source.chat_id)
            await asyncio.to_thread(publish, session_id, force=True)
    except Exception as exc:
        logger.warning("Loopdy goal refresh failed (%s)", type(exc).__name__)


def _context_window_snapshot(self, session_id: str, *, logger) -> dict[str, Any] | None:
    """Read the live/cached gateway state used by Hermes /status and /context."""

    resolver = getattr(
        getattr(self, "_session_store", None),
        "lookup_by_session_id",
        None,
    )
    if not callable(resolver):
        return None
    entry = resolver(session_id)
    session_key = str(getattr(entry, "session_key", "") or "").strip()
    runner = getattr(self, "gateway_runner", None)
    if not session_key or runner is None:
        return None
    agent = (getattr(runner, "_running_agents", None) or {}).get(session_key)
    compressor = getattr(agent, "context_compressor", None)
    if compressor is None:
        cache = getattr(runner, "_agent_cache", None)
        cache_lock = getattr(runner, "_agent_cache_lock", None)
        try:
            if cache_lock is not None:
                with cache_lock:
                    cached = cache.get(session_key) if cache is not None else None
            else:
                cached = cache.get(session_key) if cache is not None else None
            if cached:
                agent = cached[0]
                compressor = getattr(agent, "context_compressor", None)
        except Exception:
            agent = None
            compressor = None
    if agent is None or compressor is None:
        return None

    def nonnegative_int(value: Any) -> int:
        try:
            return max(0, int(value))
        except (TypeError, ValueError):
            return 0

    used = nonnegative_int(getattr(compressor, "last_prompt_tokens", 0))
    if not used:
        used = nonnegative_int(getattr(entry, "last_prompt_tokens", 0))
    maximum = nonnegative_int(getattr(compressor, "context_length", 0))
    model = str(getattr(agent, "model", "") or "").strip()
    if not model or not maximum:
        return None

    title = ""
    session_db = getattr(runner, "_session_db", None)
    session_db = getattr(session_db, "_db", session_db)
    title_reader = getattr(session_db, "get_session_title", None)
    if callable(title_reader):
        try:
            title = str(title_reader(session_id) or "").strip()[:240]
        except Exception:
            title = ""

    snapshot = {
        "model": model,
        "contextUsed": used,
        "contextMax": maximum,
        "contextPercent": min(100, round((used / maximum) * 100)),
        "compressions": nonnegative_int(
            getattr(compressor, "compression_count", 0)
        ),
        "isCompacting": (
            getattr(agent, "_active_compression_lock_holder", None) is not None
        ),
    }
    if title:
        snapshot["title"] = title

    # Per-request usage belongs to the activity broker's public-hook state.
    # Keep it separate from Hermes runner internals so reconnect snapshots
    # can reuse the same verified session/model projection.
    usage_reader = getattr(self.activity_broker, "usage_snapshot", None)
    try:
        usage = usage_reader(session_id, model) if callable(usage_reader) else None
    except Exception as exc:
        logger.warning("Loopdy usage snapshot failed (%s)", type(exc).__name__)
        usage = None
    if isinstance(usage, dict):
        for key in (
            "inputTokens", "outputTokens", "cachedTokens", "totalTokens",
            "sessionInputTokens", "sessionOutputTokens",
            "sessionCachedTokens", "sessionTotalTokens",
        ):
            value = usage.get(key)
            if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
                snapshot[key] = value
        if any(key.startswith("session") for key in usage):
            snapshot["sessionIncludesSubagents"] = True
        prompt_tokens = snapshot.get("inputTokens")
        if prompt_tokens is not None:
            snapshot["contextUsed"] = prompt_tokens
            snapshot["contextPercent"] = min(
                100, round((prompt_tokens / maximum) * 100)
            )

    return snapshot


def _link_session_key(self, source: SessionSource) -> str:
    return build_session_key(
        source,
        group_sessions_per_user=self.config.extra.get(
            "group_sessions_per_user", True
        ),
        thread_sessions_per_user=self.config.extra.get(
            "thread_sessions_per_user", False
        ),
        profile=self._session_key_profile(source),
    )


def _is_link_session_active(
    self,
    agent_id: str,
    session_id: str,
    _stored_id: str,
) -> bool:
    """Reconcile persisted catalog activity with the live Hermes owner."""
    source = self.build_source(
        chat_id=session_id,
        chat_name="Loopdy chat",
        chat_type="dm",
        user_id="loopdy-session-state",
        user_name="Loopdy",
        message_id="loopdy-session-state-refresh",
    )
    source.profile = agent_id
    session_key = self._link_session_key(source)
    if session_key in self._active_sessions:
        self._heal_stale_session_lock(session_key)
    return session_key in self._active_sessions


def _remember_verified_link_profile(
    self, session_id: str, profile: str, *, _MAX_LINK_SESSION_PROFILE_BINDINGS, _is_link_chat_id,
    _profile_coordinate,
) -> None:
    resolved_profile = _profile_coordinate(profile)
    if not _is_link_chat_id(session_id) or not resolved_profile:
        raise ValueError("Loopdy Link session profile is invalid")
    existing = self._link_session_profiles.get(session_id)
    if existing is not None and existing != resolved_profile:
        raise ValueError("Loopdy Link session cannot change agents")
    self._link_session_profiles.pop(session_id, None)
    self._link_session_profiles[session_id] = resolved_profile
    while len(self._link_session_profiles) > _MAX_LINK_SESSION_PROFILE_BINDINGS:
        self._link_session_profiles.popitem(last=False)


async def _set_link_session_workspace(
    self,
    agent_id: str,
    session_id: str,
    cwd: str, *, _MAX_LINK_SESSION_PROFILE_BINDINGS) -> None:
    """Bind one verified Link chat to a Hermes-owned project directory."""
    self._remember_verified_link_profile(session_id, agent_id)
    session_store = getattr(self, "_session_store", None)
    if session_store is None:
        raise RuntimeError("Hermes session storage is unavailable")

    from hermes_cli.profiles import get_profile_dir, profile_exists
    from hermes_constants import (
        reset_hermes_home_override,
        set_hermes_home_override,
    )
    from tools.terminal_tool import register_task_env_overrides

    if not profile_exists(agent_id):
        raise ValueError("The selected agent is unavailable")
    source = self.build_source(
        chat_id=session_id,
        chat_name="Loopdy chat",
        chat_type="dm",
    )
    source.profile = agent_id

    token = set_hermes_home_override(get_profile_dir(agent_id))
    try:
        session_key = self._link_session_key(source)
        lookup = getattr(session_store, "lookup_by_session_key", None)
        entry = await asyncio.to_thread(lookup, session_key) if callable(lookup) else None
        workspace_override = {"cwd": cwd, "cwd_source": "project"}
        if entry is None:
            # Match session.create {cwd}: seed the live routing coordinate
            # without materializing an empty persisted conversation.
            register_task_env_overrides(session_key, workspace_override)
        else:
            session_db = getattr(session_store, "_db", None)
            if session_db is None:
                raise RuntimeError("Hermes session database is unavailable")
            generation = await asyncio.to_thread(
                session_db.update_session_cwd,
                entry.session_id,
                cwd,
                replace_git_meta=True,
            )
            if (
                isinstance(generation, bool)
                or not isinstance(generation, int)
                or generation < 1
            ):
                raise RuntimeError("Hermes did not persist the session workspace")
            register_task_env_overrides(session_key, workspace_override)
            register_task_env_overrides(entry.session_id, workspace_override)
    finally:
        reset_hermes_home_override(token)

    workspace_key = (agent_id, session_id)
    if entry is None:
        self._link_session_workspaces.pop(workspace_key, None)
        self._link_session_workspaces[workspace_key] = cwd
        while len(self._link_session_workspaces) > _MAX_LINK_SESSION_PROFILE_BINDINGS:
            self._link_session_workspaces.popitem(last=False)
    else:
        self._link_session_workspaces.pop(workspace_key, None)
        runner = getattr(self, "gateway_runner", None)
        evict = getattr(runner, "_evict_cached_agent", None)
        if callable(evict):
            evict(entry.session_key)


async def _materialize_pending_link_session_workspace(
    self,
    agent_id: str,
    session_id: str,
    source: SessionSource,
) -> None:
    workspace_key = (agent_id, session_id)
    cwd = self._link_session_workspaces.get(workspace_key)
    if cwd is None:
        return

    session_store = getattr(self, "_session_store", None)
    create = getattr(session_store, "get_or_create_session", None)
    session_db = getattr(session_store, "_db", None)
    if not callable(create) or session_db is None:
        raise RuntimeError("Hermes session storage is unavailable")

    from hermes_cli.profiles import get_profile_dir, profile_exists
    from hermes_constants import (
        reset_hermes_home_override,
        set_hermes_home_override,
    )
    from tools.terminal_tool import register_task_env_overrides

    if not profile_exists(agent_id):
        raise ValueError("The selected agent is unavailable")
    token = set_hermes_home_override(get_profile_dir(agent_id))
    try:
        entry = await asyncio.to_thread(create, source)
        generation = await asyncio.to_thread(
            session_db.update_session_cwd,
            entry.session_id,
            cwd,
            replace_git_meta=True,
        )
        if (
            isinstance(generation, bool)
            or not isinstance(generation, int)
            or generation < 1
        ):
            raise RuntimeError("Hermes did not persist the session workspace")
        workspace_override = {"cwd": cwd, "cwd_source": "project"}
        register_task_env_overrides(entry.session_key, workspace_override)
        register_task_env_overrides(entry.session_id, workspace_override)
    finally:
        reset_hermes_home_override(token)

    if self._link_session_workspaces.get(workspace_key) == cwd:
        self._link_session_workspaces.pop(workspace_key, None)
    runner = getattr(self, "gateway_runner", None)
    evict = getattr(runner, "_evict_cached_agent", None)
    if callable(evict):
        evict(entry.session_key)


async def _get_link_session_workspace(
    self,
    agent_id: str,
    session_id: str,
) -> str | None:
    """Read the exact Hermes session cwd without creating another session."""

    session_store = getattr(self, "_session_store", None)
    if session_store is None:
        raise RuntimeError("Hermes session storage is unavailable")
    source = self.build_source(
        chat_id=session_id,
        chat_name="Loopdy chat",
        chat_type="dm",
    )
    source.profile = agent_id
    session_key = self._link_session_key(source)

    def load() -> str:
        from hermes_cli.profiles import get_profile_dir, profile_exists
        from hermes_constants import (
            reset_hermes_home_override,
            set_hermes_home_override,
        )

        if not profile_exists(agent_id):
            raise RuntimeError("The selected agent is unavailable")
        token = set_hermes_home_override(get_profile_dir(agent_id))
        try:
            lookup = getattr(session_store, "lookup_by_session_key", None)
            entry = lookup(session_key) if callable(lookup) else None
            if entry is None:
                return self._link_session_workspaces.get((agent_id, session_id))
            origin = getattr(entry, "origin", None)
            if (
                getattr(getattr(entry, "platform", None), "value", None)
                != "loopdy"
                or getattr(getattr(origin, "platform", None), "value", None)
                != "loopdy"
                or getattr(origin, "chat_id", None) != session_id
                or getattr(origin, "profile", None) != agent_id
            ):
                raise RuntimeError("Hermes session ownership is unavailable")
            session_db = getattr(session_store, "_db", None)
            getter = getattr(session_db, "get_session", None)
            row = getter(entry.session_id) if callable(getter) else None
            cwd = row.get("cwd") if isinstance(row, dict) else None
            if not isinstance(cwd, str) or not cwd.strip():
                pending = self._link_session_workspaces.get((agent_id, session_id))
                if pending is not None:
                    return pending
                raise RuntimeError("Hermes session workspace is unavailable")
            return cwd
        finally:
            reset_hermes_home_override(token)

    return await asyncio.to_thread(load)


def _link_response_profile(
    self,
    session_id: str,
    metadata: Dict[str, Any], *, _active_profile_id, _profile_coordinate) -> str:
    explicit = _profile_coordinate(
        metadata.get("profile") or metadata.get("profile_name")
    )
    verified = self._link_session_profiles.get(session_id, "")
    if explicit and verified and explicit != verified:
        raise ValueError("Loopdy Link response agent does not match its session")
    return explicit or verified or _active_profile_id()


async def _workspace_history_context(
    self, request: WorkspaceRequest, result: dict[str, Any]
) -> dict[str, Any] | None:
    """Read current context only after profile-scoped history succeeded.

    The controller resolves visible aliases through its authorized catalog;
    only its returned storedId is a provider coordinate. The wire snapshot
    retains the requested coordinate, not that internal alias resolution.
    """
    try:
        requested = _session_coordinate(request.payload.get("storedId"))
    except ValueError:
        return None
    envelope = {"sessionId": requested, "available": False, "snapshot": None}
    agent_id = request.payload.get("agentId")
    if not isinstance(agent_id, str) or not agent_id or result.get("agentId") != agent_id:
        return envelope
    try:
        stored_id = _session_coordinate(result.get("storedId"))
        # A known live binding must agree with the successful controller.
        for coordinate in (requested, stored_id):
            bound = self._link_session_profiles.get(coordinate)
            if bound is not None and bound != agent_id:
                return envelope
        current = await asyncio.to_thread(self._context_window_snapshot, stored_id)
        if not isinstance(current, dict):
            return envelope
        snapshot = session_context(
            session_id=requested,
            model=current["model"],
            context_used=current["contextUsed"],
            context_max=current["contextMax"],
            context_percent=current["contextPercent"],
            compressions=current["compressions"],
            is_compacting=current["isCompacting"],
            updated_at=current.get("updatedAt", int(time.time())),
            title=current.get("title"),
            input_tokens=current.get("inputTokens"),
            output_tokens=current.get("outputTokens"),
            cached_tokens=current.get("cachedTokens"),
            total_tokens=current.get("totalTokens"),
            session_input_tokens=current.get("sessionInputTokens"),
            session_output_tokens=current.get("sessionOutputTokens"),
            session_cached_tokens=current.get("sessionCachedTokens"),
            session_total_tokens=current.get("sessionTotalTokens"),
            session_includes_subagents=current.get("sessionIncludesSubagents"),
        )
    except Exception:
        # Provider absence/failure is not a failed history load. Never log
        # payloads or exception text from this optional private boundary.
        return envelope
    return {"sessionId": requested, "available": True, "snapshot": snapshot}
