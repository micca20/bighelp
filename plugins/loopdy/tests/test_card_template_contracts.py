from __future__ import annotations

import asyncio
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from loopdy_plugin.link_contracts import parse_workspace_request, workspace_result
from loopdy_plugin.loopdy_cards import canonical_json
from loopdy_plugin.store import LoopdyStore
from loopdy_plugin.workspace_control import HermesWorkspaceBackend, WorkspaceController


PLUGIN_ROOT = Path(__file__).resolve().parents[1]
CARD_FIXTURE = PLUGIN_ROOT / "fixtures" / "loopdy_card_v1" / "static-metrics.json"


def _template() -> dict:
    document = json.loads(CARD_FIXTURE.read_text(encoding="utf-8"))
    return {
        "id": "system-health",
        "version": 1,
        "name": "System health",
        "summary": "Show bounded system health metrics.",
        "author": "Loopdy",
        "license": "MIT",
        "minimum_card_version": 1,
        "parameters_schema": {
            "type": "object",
            "properties": {},
            "required": [],
            "additionalProperties": False,
        },
        "document": document,
        "sha256": hashlib.sha256(canonical_json(document).encode("utf-8")).hexdigest(),
    }


class CardTemplateWorkspaceContractTests(unittest.TestCase):
    def test_parser_dispatcher_and_store_are_profile_scoped_without_registration_side_effects(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = LoopdyStore(Path(directory) / "loopdy.sqlite3")
            controller = WorkspaceController(
                backend=HermesWorkspaceBackend(service=SimpleNamespace(store=store))
            )
            wire = {
                "version": 1,
                "type": "workspace.request",
                "requestId": "card-template-request-0001",
                "operation": "cards.templates.install",
                "payload": {"agentId": "personal", "template": _template()},
                "sentAt": 1_788_000_001,
            }

            try:
                request = parse_workspace_request(wire)
            except ValueError as error:
                self.fail(f"static card workspace parser rejected its declared operation: {error}")
            installed = asyncio.run(controller.execute(request))
            result = workspace_result(
                request=request,
                status="completed",
                payload=installed,
                sent_at=1_788_000_002,
            )

            self.assertEqual(result["requestId"], wire["requestId"])
            self.assertEqual(result["operation"], "cards.templates.install")
            self.assertTrue(result["payload"]["changed"])
            self.assertEqual(
                store.get_card_template(
                    profile="personal", template_id="system-health"
                ),
                _template(),
            )
            self.assertIsNone(
                store.get_card_template(
                    profile="research", template_id="system-health"
                )
            )

    def test_marketplace_skill_operations_are_not_part_of_the_workspace_contract(self) -> None:
        controller = WorkspaceController(
            backend=object()
        )
        self.assertNotIn("marketplace.skills.install", controller.operations)
        self.assertNotIn("marketplace.skills.status", controller.operations)
        for operation in ("marketplace.skills.install", "marketplace.skills.status"):
            with self.subTest(operation=operation), self.assertRaises(ValueError):
                parse_workspace_request({
                    "version": 1,
                    "type": "workspace.request",
                    "requestId": "removed-marketplace-request",
                    "operation": operation,
                    "payload": {},
                    "sentAt": 1_788_000_001,
                })


if __name__ == "__main__":
    unittest.main()
