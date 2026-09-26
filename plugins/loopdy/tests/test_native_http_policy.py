"""Characterize the existing HTTP boundaries before sharing their mechanics."""
from __future__ import annotations

import json
import math
import unittest
from typing import Any

from pydantic import BaseModel
from starlette.requests import ClientDisconnect, Request

from loopdy_plugin import agent_templates, native_api, workspace_artifacts
from loopdy_plugin.native_context import NativeContext


REQUEST_ID = "12345678-1234-4234-8234-123456789abc"
OWNER = NativeContext(provider="fixture", user_id="fixture-user", display_name="Fixture",
                      serving_profile_id="default", features=(), runtime_id="fixture-runtime")
FAMILIES = (native_api, agent_templates, workspace_artifacts)


def request(body: bytes = b"{}", *, headers=None, query=b"", disconnect=False):
    chunks = [body[:len(body) // 2], body[len(body) // 2:]]

    async def receive():
        if not chunks or (disconnect and len(chunks) == 1):
            return {"type": "http.disconnect"}
        return {"type": "http.request", "body": chunks.pop(0), "more_body": bool(chunks)}

    return Request({
        "type": "http", "method": "POST", "path": "/fixture", "query_string": query,
        "headers": [(key.encode(), value.encode()) for key, value in
                    (headers if headers is not None else [("content-type", "application/json")])],
    }, receive)


def body_model(module):
    return agent_templates._OwnerBody if module is agent_templates else module._Body


async def decode(module, value):
    if module is workspace_artifacts:
        return await module._body(value)
    return await module._body(value, body_model(module))


def valid_body(module):
    return b'{"path":"notes.txt"}' if module is workspace_artifacts else b'{"agentId":"default"}'


def invalid_message(module):
    if module is native_api:
        return "The native request is invalid."
    if module is agent_templates:
        return "The agent-template request is invalid."
    return "The workspace file request is invalid."


class JSONValue(BaseModel):
    value: Any


class NativeHTTPPolicyTests(unittest.IsolatedAsyncioTestCase):
    def assert_error(self, error, status, code, message):
        self.assertEqual((error.status, error.code, error.message), (status, code, message))

    async def test_streamed_body_caps_accept_exact_limit_and_reject_next_byte(self):
        for module in FAMILIES:
            with self.subTest(family=module.__name__):
                body = valid_body(module)
                body += b" " * (module.MAX_BODY_BYTES - len(body))
                result = await decode(module, request(body))
                self.assertIsInstance(result, body_model(module))
                with self.assertRaises(module.NativeAPIError if module is not agent_templates
                                       else module.AgentTemplateError) as caught:
                    await decode(module, request(body + b" "))
                message = ("The workspace file request exceeds the byte limit."
                           if module is workspace_artifacts else "The request exceeds the byte limit.")
                self.assert_error(caught.exception, 413, "payload_too_large", message)

    async def test_invalid_json_preserves_family_errors(self):
        for module in FAMILIES:
            field = b"path" if module is workspace_artifacts else b"agentId"
            malformed = [
                b'{"' + field + b'":"default","' + field + b'":"other"}',
                b'{"' + field + b'":"\xff"}',
                b'{"' + field + b'":NaN}', b'{"' + field + b'":Infinity}',
                b'{"' + field + b'":-Infinity}', b"{", b"[]",
            ]
            for body in malformed:
                with self.subTest(family=module.__name__, body=body):
                    with self.assertRaises(Exception) as caught:
                        await decode(module, request(body))
                    self.assert_error(caught.exception, 422, "invalid_request", invalid_message(module))

    async def test_query_and_content_type_precedence_stays_explicit(self):
        for module in FAMILIES:
            for query in (b"", b"extra=1"):
                with self.subTest(family=module.__name__, query=query):
                    with self.assertRaises(Exception) as caught:
                        await decode(module, request(valid_body(module), query=query, headers=[]))
                    message = ("A JSON workspace file request is required." if module is workspace_artifacts
                               else "Query fields are not supported." if query else "A JSON request is required.")
                    self.assert_error(caught.exception, 422, "invalid_request", message)
            result = await decode(module, request(valid_body(module),
                                  headers=[("content-type", "Application/JSON; charset=utf-8")]))
            self.assertIsInstance(result, body_model(module))

    async def test_disconnect_is_not_reclassified_as_invalid_json(self):
        for module in FAMILIES:
            with self.subTest(family=module.__name__), self.assertRaises(ClientDisconnect):
                await decode(module, request(valid_body(module), disconnect=True))

    async def test_native_and_template_depth_begins_at_zero(self):
        for module in (native_api, agent_templates):
            value: Any = "leaf"
            for _ in range(23):
                value = [value]
            accepted = json.dumps({"value": value}).encode()
            self.assertEqual((await module._body(request(accepted), JSONValue)).value, value)
            with self.subTest(family=module.__name__), self.assertRaises(Exception) as caught:
                await module._body(request(json.dumps({"value": [value]}).encode()), JSONValue)
            self.assert_error(caught.exception, 422, "invalid_request", invalid_message(module))

    async def test_number_token_policy_does_not_invent_an_overflow_walk(self):
        for module in (native_api, agent_templates):
            with self.subTest(family=module.__name__):
                value = await module._body(request(b'{"value":1e999}'), JSONValue)
                self.assertTrue(math.isinf(value.value))

    def test_preconditions_preserve_error_order_and_header_multiplicity(self):
        for module in FAMILIES:
            artifact = module is workspace_artifacts
            required = "Load the current native context before this request." if artifact else "Load native context before this request."
            changed = required if artifact else "The native context changed; refresh before retrying."
            cases = [
                ([], 428, "context_required", required),
                ([("if-match", '"stale"')], 412, "context_changed", changed),
                ([("if-match", OWNER.etag)] * 2, 412, "context_changed", changed),
                ([("if-match", OWNER.etag)], 422, "invalid_request", "A canonical request ID is required."),
            ]
            for headers, status, code, message in cases:
                with self.subTest(family=module.__name__, headers=headers), self.assertRaises(Exception) as caught:
                    module._precondition(request(headers=headers), OWNER)
                self.assert_error(caught.exception, status, code, message)
            valid = [("if-match", OWNER.etag), ("x-loopdy-request-id", REQUEST_ID)]
            self.assertEqual(module._precondition(request(headers=valid), OWNER), REQUEST_ID)
            for identifiers in ([REQUEST_ID, REQUEST_ID], [REQUEST_ID.upper()], [""],
                                ["12345678-1234-0234-8234-123456789abc"]):
                headers = [("if-match", OWNER.etag)] + [("x-loopdy-request-id", value) for value in identifiers]
                with self.subTest(family=module.__name__, identifiers=identifiers), self.assertRaises(Exception) as caught:
                    module._precondition(request(headers=headers), OWNER)
                self.assert_error(caught.exception, 422, "invalid_request", "A canonical request ID is required.")

    def test_response_encoding_is_exact_and_correlated(self):
        value = {"z": "\ufeffCafé\r\n👨‍👩‍👧‍👦", "a": [1, None, True]}
        expected = json.dumps(value, ensure_ascii=False, sort_keys=True,
                              separators=(",", ":"), allow_nan=False).encode("utf-8")
        for module in (native_api, agent_templates):
            with self.subTest(family=module.__name__):
                response = module._response(value, OWNER, REQUEST_ID)
                self.assertEqual(response.body, expected)
                self.assertEqual(response.headers["etag"], OWNER.etag)
                self.assertEqual(response.headers["x-loopdy-request-id"], REQUEST_ID)
                self.assertEqual(response.headers["cache-control"], "no-store")
                with self.assertRaises(ValueError):
                    module._response({"value": float("inf")}, OWNER, REQUEST_ID)
        response = native_api._response(value, OWNER)
        self.assertNotIn("x-loopdy-request-id", response.headers)

    def test_response_caps_distinguish_context_native_and_template(self):
        for module, request_id, maximum in ((native_api, None, 16_384),
                                          (native_api, REQUEST_ID, native_api.MAX_BODY_BYTES),
                                          (agent_templates, REQUEST_ID, agent_templates.MAX_RESPONSE_BYTES)):
            with self.subTest(family=module.__name__, maximum=maximum):
                overhead = len(json.dumps({"value": ""}, separators=(",", ":")).encode())
                value = {"value": "x" * (maximum - overhead)}
                self.assertEqual(len(module._response(value, OWNER, request_id).body), maximum)
                value["value"] += "x"
                with self.assertRaises(Exception) as caught:
                    module._response(value, OWNER, request_id)
                self.assert_error(caught.exception, 413, "payload_too_large", "The response exceeds the byte limit.")
