#!/usr/bin/env python3
"""Measure tracked source at any two Git revisions, without counting moves twice.

    uv run --with pygount python Scripts/measure-source.py BASE [HEAD]

Production excludes tests, developer tooling, generated bundles, and vendored
code. Those categories remain visible in the whole-repository total. Blank and
comment lines cannot satisfy the production code reduction gate.
"""
from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import subprocess
import tempfile

from pygount import SourceAnalysis, SourceState

SOURCE_SUFFIXES = {".swift", ".py", ".ts", ".tsx", ".js", ".mjs", ".cjs", ".sh", ".rb"}


def git(*args: str) -> bytes:
    return subprocess.check_output(["git", *args])


def category(path: str) -> str:
    parts = Path(path).parts
    if parts[0] in {"Vendor", "Packages"} or "/recovered/" in path:
        return "vendor_or_generated"
    if any(p.lower() in {"tests", "test", "__tests__"} or p.endswith("Tests") for p in parts):
        return "tests"
    if parts[0] in {"Scripts", "scripts", "fastlane", ".github", "bin"}:
        return "tooling"
    return "production"


def measure(revision: str) -> dict:
    commit = git("rev-parse", revision).decode().strip()
    paths = sorted(p for p in git("ls-tree", "-r", "--name-only", commit).decode().splitlines()
                   if Path(p).suffix in SOURCE_SUFFIXES)
    totals: dict[str, Counter] = {}
    rows = []
    with tempfile.TemporaryDirectory(prefix="loopdy-metrics-") as directory:
        for path in paths:
            content = git("show", f"{commit}:{path}")
            scratch = Path(directory) / Path(path).name
            scratch.write_bytes(content)
            # No duplicate suppression: duplicating source is real maintenance cost.
            analysis = SourceAnalysis.from_file(str(scratch), "source", encoding="utf-8")
            if not analysis.is_countable and analysis.state not in {SourceState.generated, SourceState.empty}:
                raise RuntimeError(f"Cannot measure {path}: {analysis.state} {analysis.state_info}")
            values = {"physical": len(content.splitlines()), "code": analysis.code_count,
                      "comments": analysis.documentation_count, "blank": analysis.empty_count}
            group = category(path)
            totals.setdefault(group, Counter()).update(values)
            rows.append({"path": path, "category": group, **values})
    return {"revision": commit, "categories": totals,
            "total": sum(totals.values(), Counter()), "files": rows}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base")
    parser.add_argument("candidate", nargs="?", default="HEAD")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    baseline, candidate = measure(args.base), measure(args.candidate)
    changes = {}
    groups = baseline["categories"].keys() | candidate["categories"].keys() | {"overall"}
    for group in sorted(groups):
        before = baseline["total"] if group == "overall" else baseline["categories"].get(group, {})
        after = candidate["total"] if group == "overall" else candidate["categories"].get(group, {})
        changes[group] = {
            metric: {"before": before.get(metric, 0), "after": after.get(metric, 0),
                     "reduction_percent": round(100 * (before.get(metric, 0) - after.get(metric, 0))
                                                / before[metric], 2) if before.get(metric) else None}
            for metric in ("physical", "code")
        }
    result = {"baseline": baseline, "candidate": candidate, "changes": changes}
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"baseline": baseline["revision"], "candidate": candidate["revision"],
                      "changes": changes}, indent=2))


if __name__ == "__main__":
    main()
