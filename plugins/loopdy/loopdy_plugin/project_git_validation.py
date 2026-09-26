"""Project Git value validation shared by wire and backend boundaries.

Each boundary supplies its original exception type and user-safe wording. No
policy, authorization, filesystem access or operation dispatch lives here.
"""

from __future__ import annotations

import re
from typing import Any


class ProjectGitValidation:
    def __init__(self, error_type: type[Exception], prefix: str, *, choice_label: str):
        self.error_type = error_type
        self.prefix = prefix
        self.choice_label = choice_label

    def _invalid(self, label: str) -> Exception:
        return self.error_type(f"{self.prefix} {label} is invalid")

    def operation_input(self, operation: str, value: Any) -> dict[str, Any]:
        if not isinstance(value, dict):
            raise self._invalid("input")
        expected = {
            "stage": {"mode", "paths"},
            "commit": {"message"},
            "fetch": {"remote"},
            "pull": {"remote", "branch"},
            "push": {"remote", "branch"},
        }[operation]
        if set(value) != expected:
            raise self._invalid("input")
        if operation == "stage":
            raw_paths = value.get("paths")
            if not isinstance(raw_paths, list) or not 1 <= len(raw_paths) <= 500:
                raise self.error_type(f"{self.prefix} paths are invalid")
            paths = [self.relative_path(path) for path in raw_paths]
            if len(set(paths)) != len(paths):
                raise self.error_type(f"{self.prefix} paths are invalid")
            return {
                "mode": self.choice(value.get("mode"), {"stage", "unstage"}),
                "paths": paths,
            }
        if operation == "commit":
            message = value.get("message")
            if (
                not isinstance(message, str)
                or not message.strip()
                or len(message.encode("utf-8")) > 10_000
                or any(ord(character) < 32 and character not in "\n\t" for character in message)
            ):
                raise self._invalid("commit message")
            return {"message": message}
        remote = self.ref(value.get("remote"), "remote")
        result = {"remote": remote}
        if operation in {"pull", "push"}:
            result["branch"] = self.ref(value.get("branch"), "branch")
        return result

    def relative_path(self, value: Any) -> str:
        if (
            not isinstance(value, str)
            or not value
            or len(value.encode("utf-8")) > 4_096
            or value.startswith(("/", "\\", "-"))
            or "\\" in value
            or ":" in value
            or any(part in {"", ".", ".."} for part in value.split("/"))
            or any(ord(character) < 32 for character in value)
            or "://" in value
        ):
            raise self._invalid("path")
        return value

    def ref(self, value: Any, label: str) -> str:
        if (
            not isinstance(value, str)
            or not value
            or len(value.encode("utf-8")) > 180
            or value.startswith(("-", "/"))
            or value.endswith(("/", "."))
            or ".." in value
            or ":" in value
            or "\\" in value
            or any(character.isspace() or ord(character) < 32 for character in value)
        ):
            raise self._invalid(label)
        return value

    def choice(self, value: Any, allowed: set[str]) -> str:
        if not isinstance(value, str) or value not in allowed:
            raise self._invalid(self.choice_label)
        return value

    def status_token(self, value: Any) -> str:
        if not isinstance(value, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", value):
            raise self._invalid("status token")
        return value
