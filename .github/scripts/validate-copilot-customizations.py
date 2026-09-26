#!/usr/bin/env python3
"""Validate Loopdy's GitHub Copilot instructions and custom agents."""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
INSTRUCTIONS = ROOT / ".github" / "copilot-instructions.md"
AGENT_DIR = ROOT / ".github" / "agents"
EXPECTED_AGENTS = {
    "loopdy-delivery-lead.agent.md",
    "loopdy-product-architect.agent.md",
    "hermes-integration-architect.agent.md",
    "loopdy-experience-designer.agent.md",
    "loopdy-ios-builder.agent.md",
    "loopdy-hermes-plugin-builder.agent.md",
    "loopdy-security-reviewer.agent.md",
    "loopdy-release-manager.agent.md",
}
ALLOWED_TOOLS = {"read", "search", "edit", "execute", "agent"}
EXPECTED_TOOLS = {
    "loopdy-security-reviewer.agent.md": {"read", "search", "execute"},
    "loopdy-release-manager.agent.md": {"read", "search", "execute"},
    "loopdy-delivery-lead.agent.md": {"read", "search", "edit", "execute", "agent"},
}
NATIVE_BOUNDARY_FILES = {
    "hermes-integration-architect.agent.md",
    "loopdy-hermes-plugin-builder.agent.md",
    "loopdy-delivery-lead.agent.md",
}
REQUIRED_BOUNDARY_TERMS = (
    "hermes",
    "authoritative",
    "shim",
    "sidecar",
    "monkeypatch",
    "installed",
    "patch",
)


class ValidationError(Exception):
    """Raised when a Copilot customization violates the repository contract."""


def parse_frontmatter(path: Path) -> tuple[dict[str, object], str]:
    text = path.read_text(encoding="utf-8")
    if not text.startswith("---\n"):
        raise ValidationError(f"{path}: missing opening YAML delimiter")

    try:
        raw_frontmatter, prompt = text[4:].split("\n---\n", 1)
    except ValueError as error:
        raise ValidationError(f"{path}: missing closing YAML delimiter") from error

    values: dict[str, object] = {}
    for line_number, raw_line in enumerate(raw_frontmatter.splitlines(), start=2):
        if not raw_line.strip() or raw_line.lstrip().startswith("#"):
            continue
        if raw_line[:1].isspace() or ":" not in raw_line:
            raise ValidationError(
                f"{path}:{line_number}: only top-level scalar and inline-list frontmatter is allowed"
            )
        key, raw_value = raw_line.split(":", 1)
        key = key.strip()
        raw_value = raw_value.strip()
        if not key or key in values:
            raise ValidationError(f"{path}:{line_number}: invalid or duplicate key {key!r}")
        if raw_value.startswith("["):
            if not raw_value.endswith("]"):
                raise ValidationError(f"{path}:{line_number}: malformed inline list")
            body = raw_value[1:-1].strip()
            value: object = [item.strip().strip("'\"") for item in body.split(",") if item.strip()]
        elif raw_value.lower() in {"true", "false"}:
            value = raw_value.lower() == "true"
        else:
            value = raw_value.strip("'\"")
        values[key] = value

    return values, prompt


def require_terms(label: str, text: str, terms: tuple[str, ...]) -> None:
    lowered = text.lower()
    missing = [term for term in terms if term not in lowered]
    if missing:
        raise ValidationError(f"{label}: missing required terms: {', '.join(missing)}")


def validate() -> None:
    if not INSTRUCTIONS.is_file():
        raise ValidationError(f"missing {INSTRUCTIONS.relative_to(ROOT)}")

    instructions = INSTRUCTIONS.read_text(encoding="utf-8")
    if len(instructions) > 20_000:
        raise ValidationError(
            f"{INSTRUCTIONS.relative_to(ROOT)} exceeds 20,000 characters: {len(instructions)}"
        )
    require_terms(
        str(INSTRUCTIONS.relative_to(ROOT)),
        instructions,
        REQUIRED_BOUNDARY_TERMS
        + ("xcodegen generate", "hermes plugins doctor", "tui gateway"),
    )

    actual_agents = {path.name for path in AGENT_DIR.glob("*.agent.md")}
    missing_agents = EXPECTED_AGENTS - actual_agents
    unexpected_agents = actual_agents - EXPECTED_AGENTS
    if missing_agents or unexpected_agents:
        details = []
        if missing_agents:
            details.append(f"missing: {', '.join(sorted(missing_agents))}")
        if unexpected_agents:
            details.append(f"unexpected: {', '.join(sorted(unexpected_agents))}")
        raise ValidationError("agent file set mismatch; " + "; ".join(details))

    names: dict[str, str] = {}
    for filename in sorted(EXPECTED_AGENTS):
        path = AGENT_DIR / filename
        frontmatter, prompt = parse_frontmatter(path)

        unknown_keys = set(frontmatter) - {
            "name",
            "description",
            "tools",
            "disable-model-invocation",
            "target",
            "model",
            "user-invocable",
            "metadata",
            "mcp-servers",
        }
        if unknown_keys:
            raise ValidationError(f"{filename}: unsupported keys: {', '.join(sorted(unknown_keys))}")
        if "handoffs" in frontmatter:
            raise ValidationError(f"{filename}: cloud agent ignores handoffs frontmatter")

        name = frontmatter.get("name")
        description = frontmatter.get("description")
        tools = frontmatter.get("tools")
        if not isinstance(name, str) or not name.strip():
            raise ValidationError(f"{filename}: name is required")
        if not isinstance(description, str) or not description.strip():
            raise ValidationError(f"{filename}: description is required")
        if not isinstance(tools, list) or not tools:
            raise ValidationError(f"{filename}: an explicit nonempty tools list is required")
        tool_set = set(tools)
        unsupported_tools = tool_set - ALLOWED_TOOLS
        if unsupported_tools:
            raise ValidationError(
                f"{filename}: unsupported tools: {', '.join(sorted(unsupported_tools))}"
            )
        if len(tools) != len(tool_set):
            raise ValidationError(f"{filename}: duplicate tool aliases")
        if len(prompt) > 30_000:
            raise ValidationError(f"{filename}: prompt exceeds 30,000 characters: {len(prompt)}")
        if not prompt.strip():
            raise ValidationError(f"{filename}: prompt is empty")
        if frontmatter.get("disable-model-invocation") is not True:
            raise ValidationError(f"{filename}: must require deliberate manual selection")

        normalized_name = re.sub(r"\s+", " ", name.strip()).casefold()
        if normalized_name in names:
            raise ValidationError(
                f"{filename}: duplicate name also used by {names[normalized_name]}"
            )
        names[normalized_name] = filename

        expected_tools = EXPECTED_TOOLS.get(filename)
        if expected_tools is not None and tool_set != expected_tools:
            raise ValidationError(
                f"{filename}: expected tools {sorted(expected_tools)}, got {sorted(tool_set)}"
            )
        if filename != "loopdy-delivery-lead.agent.md" and "agent" in tool_set:
            raise ValidationError(f"{filename}: only the delivery lead may invoke other agents")
        if filename in NATIVE_BOUNDARY_FILES:
            require_terms(filename, prompt, REQUIRED_BOUNDARY_TERMS)

    print(
        "Validated 1 repository instruction file and "
        f"{len(EXPECTED_AGENTS)} Loopdy custom agent profiles."
    )


def main() -> int:
    try:
        validate()
    except (OSError, UnicodeError, ValidationError) as error:
        print(f"Copilot customization validation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
