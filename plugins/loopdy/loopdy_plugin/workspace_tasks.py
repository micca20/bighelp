"""Scheduled-task projections and explicit Hermes cron operations."""

from __future__ import annotations

import asyncio
import inspect
from typing import Any
from .workspace_common import (
    WorkspaceControlError,
    _agent_id,
    _coordinate,
    _empty_payload,
    _identifier,
    _nonnegative_integer,
    _object,
    _optional_coordinate,
    _optional_object,
    _optional_time_value,
    _text,
)
from .workspace_profiles import (
    _reasoning,
)


def _scheduled_task_draft(payload: Any) -> dict[str, str]:
    values = _object(payload, "workspace payload")
    if set(values) != {"agentId", "name", "instructions", "schedule", "delivery"}:
        raise WorkspaceControlError("Scheduled task payload is invalid")
    return {
        "agentId": _agent_id(values.get("agentId")),
        "name": _text(values.get("name"), 240),
        "instructions": _text(values.get("instructions"), 256_000),
        "schedule": _text(values.get("schedule"), 2_048),
        "delivery": _text(values.get("delivery"), 512),
    }


def _delivery_target_catalog(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list) or len(value) > 64:
        raise WorkspaceControlError("Hermes delivery target catalog is invalid")
    targets = [{
        "id": "local",
        "name": "Local (save only)",
        "homeTargetSet": True,
    }]
    seen = {"local"}
    for raw in value:
        source = _object(raw, "Hermes delivery target")
        target_id = _text(source.get("id"), 160)
        if target_id in seen:
            raise WorkspaceControlError("Hermes delivery target catalog is invalid")
        home_target_set = source.get("home_target_set")
        if type(home_target_set) is not bool:
            raise WorkspaceControlError("Hermes delivery target catalog is invalid")
        seen.add(target_id)
        targets.append({
            "id": target_id,
            "name": _text(source.get("name"), 160),
            "homeTargetSet": home_target_set,
        })
    return targets


def _scheduled_task_delivery(value: Any, raw_targets: Any) -> str:
    delivery = _text(value, 512)
    targets = _delivery_target_catalog(raw_targets)
    exact = next((target for target in targets if target["id"] == delivery), None)
    if exact is not None:
        if exact["homeTargetSet"]:
            return delivery
        raise WorkspaceControlError("Scheduled task delivery home target is unavailable")

    if (
        "," in delivery
        or any(character.isspace() for character in delivery)
        or ":" not in delivery
    ):
        raise WorkspaceControlError("Scheduled task delivery is invalid")
    platform, target = delivery.split(":", 1)
    known_platforms = {
        item["id"] for item in targets
        if item["id"] not in {"local"} and ":" not in item["id"]
    }
    if platform not in known_platforms or not target or target.startswith(":"):
        raise WorkspaceControlError("Scheduled task delivery is invalid")
    return delivery


def _task_coordinate(payload: Any) -> tuple[str, str]:
    values = _object(payload, "workspace payload")
    if set(values) != {"taskId", "agentId"}:
        raise WorkspaceControlError("Scheduled task coordinate is invalid")
    return (
        _coordinate(values.get("taskId"), 160),
        _agent_id(values.get("agentId")),
    )


def _task_projection(value: Any, *, default_agent_id: str | None) -> dict[str, Any]:
    source = _object(value, "Hermes scheduled task")
    task_id = _optional_coordinate(source.get("id"), 160) or _coordinate(
        source.get("job_id"), 160
    )
    raw_profile = source.get("profile") or default_agent_id
    agent_id = _agent_id(raw_profile)
    schedule = source.get("schedule")
    request = ""
    embedded_display = ""
    if isinstance(schedule, dict):
        kind = schedule.get("kind")
        if kind == "cron":
            request = _text(schedule.get("expr"), 2_048)
        elif kind == "once":
            request = _text(schedule.get("run_at"), 2_048)
        elif kind == "interval":
            minutes = _nonnegative_integer(schedule.get("minutes"), maximum=52_560_000)
            if minutes == 0:
                raise WorkspaceControlError("Hermes scheduled task interval is invalid")
            request = f"every {minutes}m"
        else:
            for key in ("expr", "run_at"):
                if schedule.get(key):
                    request = _text(schedule.get(key), 2_048)
                    break
        if schedule.get("display") is not None:
            embedded_display = _text(schedule.get("display"), 2_048, allow_empty=True)
    elif isinstance(schedule, str):
        request = _text(schedule, 2_048)
    if not request:
        raise WorkspaceControlError("Hermes scheduled task schedule is invalid")
    display = _text(
        source.get("schedule_display"), 2_048, allow_empty=True
    ) or embedded_display or request
    raw_prompt = source.get("prompt")
    raw_script = source.get("script")
    if isinstance(raw_prompt, str) and raw_prompt.strip():
        instructions = _text(raw_prompt, 256_000)
    elif (
        source.get("no_agent") is True
        and isinstance(raw_script, str)
        and raw_script.strip()
    ):
        instructions = "Runs the configured automation."
    else:
        instructions = _text(raw_prompt, 256_000)
    result: dict[str, Any] = {
        "id": task_id,
        "agentId": agent_id,
        "name": _text(source.get("name"), 240),
        "instructions": instructions,
        "scheduleRequest": request,
        "scheduleDisplay": display,
        "delivery": _text(source.get("deliver", "local"), 512),
        "enabled": source.get("enabled") is not False,
    }
    next_run = _optional_time_value(source.get("next_run_at"))
    if next_run is not None:
        result["nextRunAt"] = next_run
    last_status = source.get("last_status")
    if last_status is not None:
        result["lastStatus"] = _text(last_status, 512, allow_empty=True)
    return result


class TaskControls:
    async def scheduled_tasks_list(self, payload: dict[str, Any]) -> dict[str, Any]:
        values = _object(payload, "workspace payload")
        if set(values) - {"agentId"}:
            raise WorkspaceControlError("Scheduled task list payload is invalid")
        agent_id = _agent_id(values["agentId"]) if "agentId" in values else None
        rows = await self._cron_list(agent_id)
        if not isinstance(rows, list) or len(rows) > 500:
            raise WorkspaceControlError("Hermes scheduled task catalog is invalid")
        return {
            "tasks": [
                _task_projection(row, default_agent_id=agent_id)
                for row in rows
            ]
        }

    async def scheduled_tasks_delivery_targets(
        self, payload: dict[str, Any]
    ) -> dict[str, Any]:
        _empty_payload(payload)
        return {"targets": _delivery_target_catalog(await self._cron_delivery_targets())}

    async def scheduled_tasks_create(self, payload: dict[str, Any]) -> dict[str, Any]:
        values = _scheduled_task_draft(payload)
        agent_id = values.pop("agentId")
        delivery = _scheduled_task_delivery(
            values.pop("delivery"),
            await self._cron_delivery_targets(),
        )
        config = _object(await self._profile_config(agent_id), "Hermes config")
        cron = _optional_object(config.get("cron"))
        platforms = _optional_object(config.get("platforms"))
        loopdy = _optional_object(platforms.get("loopdy"))
        extra = _optional_object(loopdy.get("extra"))
        agent_defaults = _optional_object(extra.get("agent_defaults"))
        scheduled = _optional_object(agent_defaults.get("scheduled_tasks"))
        provider = _identifier(
            cron.get("model_provider", cron.get("provider")), 128
        )
        model = _identifier(cron.get("model"), 256)
        reasoning = _reasoning(scheduled.get("reasoning_effort"))
        create = {
            "name": values["name"],
            "prompt": values["instructions"],
            "schedule": values["schedule"],
            "deliver": delivery,
        }
        if provider:
            create["provider"] = provider
        if model:
            create["model"] = model
        job = await self._cron_create(agent_id, create)
        task = _task_projection(job, default_agent_id=agent_id)
        if reasoning:
            job = await self._cron_update(
                task["id"], agent_id, {"reasoning_effort": reasoning}
            )
            task = _task_projection(job, default_agent_id=agent_id)
        return {"task": task}

    async def scheduled_tasks_update(self, payload: dict[str, Any]) -> dict[str, Any]:
        values = _object(payload, "workspace payload")
        if set(values) != {"taskId", "agentId", "changes"}:
            raise WorkspaceControlError("Scheduled task update payload is invalid")
        task_id = _coordinate(values.get("taskId"), 160)
        agent_id = _agent_id(values.get("agentId"))
        changes = _object(values.get("changes"), "scheduled task changes")
        if set(changes) != {"name", "instructions", "schedule", "delivery"}:
            raise WorkspaceControlError("Scheduled task changes are invalid")
        updates = {
            "name": _text(changes.get("name"), 240),
            "prompt": _text(changes.get("instructions"), 256_000),
            "schedule": _text(changes.get("schedule"), 2_048),
            "deliver": _scheduled_task_delivery(
                changes.get("delivery"),
                await self._cron_delivery_targets(),
            ),
        }
        job = await self._cron_update(task_id, agent_id, updates)
        return {"task": _task_projection(job, default_agent_id=agent_id)}

    async def scheduled_tasks_pause(self, payload: dict[str, Any]) -> dict[str, Any]:
        return await self._scheduled_task_action(payload, self._cron_pause)

    async def scheduled_tasks_resume(self, payload: dict[str, Any]) -> dict[str, Any]:
        return await self._scheduled_task_action(payload, self._cron_resume)

    async def scheduled_tasks_run(self, payload: dict[str, Any]) -> dict[str, Any]:
        return await self._scheduled_task_action(payload, self._cron_run)

    async def scheduled_tasks_delete(self, payload: dict[str, Any]) -> dict[str, Any]:
        task_id, agent_id = _task_coordinate(payload)
        await self._cron_delete(task_id, agent_id)
        return {"taskId": task_id, "deleted": True}

    async def _scheduled_task_action(self, payload: dict[str, Any], action: Any) -> dict[str, Any]:
        task_id, agent_id = _task_coordinate(payload)
        job = action(task_id, agent_id)
        if inspect.isawaitable(job):
            job = await job
        return {"task": _task_projection(job, default_agent_id=agent_id)}

    async def _cron_list(self, agent_id: str | None) -> list[dict[str, Any]]:
        from hermes_cli.web_routers.cron import _list_cron_jobs_sync

        return await asyncio.to_thread(_list_cron_jobs_sync, agent_id or "all")

    async def _cron_delivery_targets(self) -> list[dict[str, Any]]:
        from cron.scheduler_delivery import cron_delivery_targets

        return await asyncio.to_thread(cron_delivery_targets)

    async def _cron_create(
        self, agent_id: str, values: dict[str, Any]
    ) -> dict[str, Any]:
        from hermes_cli.web_models import CronJobCreate
        from hermes_cli.web_server_cron import _create_cron_job_sync

        return await asyncio.to_thread(
            _create_cron_job_sync,
            CronJobCreate(**values),
            agent_id,
        )

    async def _cron_update(
        self, task_id: str, agent_id: str, updates: dict[str, Any]
    ) -> dict[str, Any]:
        from hermes_cli.web_models import CronJobUpdate
        from hermes_cli.web_routers.cron import _update_cron_job_sync

        return await asyncio.to_thread(
            _update_cron_job_sync,
            task_id,
            CronJobUpdate(updates=updates),
            agent_id,
        )

    async def _cron_pause(self, task_id: str, agent_id: str) -> dict[str, Any]:
        from hermes_cli.web_routers.cron import _pause_cron_job_sync

        return await asyncio.to_thread(_pause_cron_job_sync, task_id, agent_id)

    async def _cron_resume(self, task_id: str, agent_id: str) -> dict[str, Any]:
        from hermes_cli.web_routers.cron import _resume_cron_job_sync

        return await asyncio.to_thread(_resume_cron_job_sync, task_id, agent_id)

    async def _cron_run(self, task_id: str, agent_id: str) -> dict[str, Any]:
        from hermes_cli.web_routers.cron import _trigger_cron_job_sync

        return await asyncio.to_thread(_trigger_cron_job_sync, task_id, agent_id)

    async def _cron_delete(self, task_id: str, agent_id: str) -> None:
        from hermes_cli.web_routers.cron import _delete_cron_job_sync

        await asyncio.to_thread(_delete_cron_job_sync, task_id, agent_id)
