"""Small HTTP/JSON mechanics; callers retain authority and error policy."""
from __future__ import annotations

import json
from collections.abc import Callable

from fastapi import Request
from fastapi.responses import Response


def unique_pairs(pairs, *, message="Duplicate JSON key"):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(message)
        result[key] = value
    return result


def invalid_number(_value, *, message="Non-finite JSON number"):
    raise ValueError(message)


async def read_body(request: Request, *, maximum: int, oversized: Exception) -> bytearray:
    # Stream errors stay outside callers' JSON/validation exception translation.
    content = bytearray()
    async for chunk in request.stream():
        if len(content) + len(chunk) > maximum:
            raise oversized
        content.extend(chunk)
    return content


def decode_body(content, *, pairs, constant, max_depth: int | None):
    value = json.loads(content.decode("utf-8"), object_pairs_hook=pairs, parse_constant=constant)
    if max_depth is not None:
        pending = [(value, 0)]
        while pending:
            item, depth = pending.pop()
            if depth > max_depth:
                raise ValueError("JSON nesting limit")
            if isinstance(item, dict):
                pending.extend((child, depth + 1) for child in item.values())
            elif isinstance(item, list):
                pending.extend((child, depth + 1) for child in item)
    return value


def canonical_json(value) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"),
                      sort_keys=True, allow_nan=False).encode("utf-8")


def bounded_response(encoded: bytes, *, maximum: int,
                     headers: Callable[[], dict[str, str]], oversized: Exception) -> Response:
    if len(encoded) > maximum:
        raise oversized
    return Response(encoded, media_type="application/json", headers=headers())


def request_id(request: Request, pattern) -> str | None:
    value = request.headers.get("x-loopdy-request-id", "")
    if len(request.headers.getlist("x-loopdy-request-id")) == 1 and pattern.fullmatch(value):
        return value
    return None


def precondition(request: Request, context, *, pattern, error,
                 missing_message: str, changed_message: str) -> str:
    if request.headers.get("if-match") is None:
        raise error(428, "context_required", missing_message)
    if len(request.headers.getlist("if-match")) != 1 or request.headers["if-match"] != context.etag:
        raise error(412, "context_changed", changed_message)
    value = request_id(request, pattern)
    if value is None:
        raise error(422, "invalid_request", "A canonical request ID is required.")
    return value
