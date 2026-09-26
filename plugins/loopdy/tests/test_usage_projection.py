"""Usage projection consumes public API-request hooks, not agent internals."""
import asyncio
import unittest

from loopdy_plugin.activity_bridge import LinkActivityBroker


class UsageProjectionTests(unittest.IsolatedAsyncioTestCase):
    async def test_cumulative_session_family_usage_includes_finished_nested_children_once(self):
        broker = LinkActivityBroker()
        broker.bind_link_session("parent-session", "visible-link")

        broker.record_api_usage(
            session_id="parent-session", model="parent-model", turn_id="parent-turn",
            api_request_id="parent-request-1", api_call_count=1, ended_at=10,
            usage={"prompt_tokens":27_903, "output_tokens":439,
                   "cache_read_tokens":27_000, "total_tokens":28_342},
        )
        broker.record_api_usage(
            session_id="parent-session", model="parent-model", turn_id="parent-turn",
            api_request_id="parent-request-2", api_call_count=2, ended_at=20,
            usage={"prompt_tokens":50_000, "output_tokens":500,
                   "cache_read_tokens":48_000, "total_tokens":50_500},
        )
        broker.publish_subagent_lifecycle(
            "subagent_start", "visible-link",
            {"parent_session_id": "parent-session", "parent_turn_id": "parent-turn",
             "child_session_id": "child-session", "child_role": "worker"},
            occurred_at=21,
        )
        broker.record_api_usage(
            session_id="child-session", model="child-model", turn_id="child-turn",
            api_request_id="child-request", api_call_count=1, ended_at=30,
            usage={"prompt_tokens":10_000, "output_tokens":200,
                   "cache_read_tokens":9_000, "total_tokens":10_200},
        )
        broker.publish_subagent_lifecycle(
            "subagent_start", None,
            {"parent_session_id": "child-session", "parent_turn_id": "child-turn",
             "child_session_id": "grandchild-session", "child_role": "researcher"},
            occurred_at=31,
        )
        broker.record_api_usage(
            session_id="grandchild-session", model="nested-model", turn_id="nested-turn",
            api_request_id="nested-request", api_call_count=1, ended_at=40,
            usage={"prompt_tokens":5_000, "output_tokens":100,
                   "cache_read_tokens":4_000, "total_tokens":5_100},
        )

        # Replayed hooks and lifecycle completion must neither double count nor
        # discard the finished descendants from their owning session total.
        broker.record_api_usage(
            session_id="grandchild-session", model="nested-model", turn_id="nested-turn",
            api_request_id="nested-request", api_call_count=1, ended_at=40,
            usage={"prompt_tokens":5_000, "output_tokens":100,
                   "cache_read_tokens":4_000, "total_tokens":5_100},
        )
        for parent, child in (("child-session", "grandchild-session"),
                              ("parent-session", "child-session")):
            broker.publish_subagent_lifecycle(
                "subagent_stop", None,
                {"parent_session_id": parent, "parent_turn_id": "finished-turn",
                 "child_session_id": child, "child_status": "completed"},
                occurred_at=50,
            )

        usage = broker.usage_snapshot("parent-session", "parent-model")
        self.assertEqual(usage["inputTokens"], 50_000)
        self.assertEqual(usage["outputTokens"], 500)
        self.assertEqual(usage["cachedTokens"], 48_000)
        self.assertEqual(usage["totalTokens"], 50_500)
        self.assertEqual(usage["sessionInputTokens"], 92_903)
        self.assertEqual(usage["sessionOutputTokens"], 1_239)
        self.assertEqual(usage["sessionCachedTokens"], 88_000)
        self.assertEqual(usage["sessionTotalTokens"], 94_142)
        other_model = broker.usage_snapshot("parent-session", "child-model")
        self.assertNotIn("inputTokens", other_model)
        self.assertEqual(other_model["sessionTotalTokens"], 94_142)

    async def test_unknown_cumulative_cache_stays_absent_but_a_true_latest_zero_is_visible(self):
        broker = LinkActivityBroker()
        broker.bind_link_session("session-one", "link-one")
        broker.record_api_usage(
            session_id="session-one", model="model", api_request_id="request-one",
            usage={"prompt_tokens":10, "output_tokens":2, "total_tokens":12},
        )
        broker.record_api_usage(
            session_id="session-one", model="model", api_request_id="request-two",
            usage={"prompt_tokens":20, "output_tokens":3, "cache_read_tokens":0,
                   "total_tokens":23},
        )

        usage = broker.usage_snapshot("session-one", "model")
        self.assertEqual(usage["cachedTokens"], 0)
        self.assertNotIn("sessionCachedTokens", usage)
        self.assertEqual(usage["sessionInputTokens"], 30)
        self.assertEqual(usage["sessionOutputTokens"], 5)
        self.assertEqual(usage["sessionTotalTokens"], 35)

    async def test_switching_models_does_not_relabel_an_older_call_as_latest(self):
        broker = LinkActivityBroker()
        broker.bind_link_session("session-one", "link-one")
        broker.record_api_usage(
            session_id="session-one", model="old-model", api_request_id="old-request",
            ended_at=1, usage={"prompt_tokens":10, "output_tokens":2, "total_tokens":12},
        )
        broker.record_api_usage(
            session_id="session-one", model="new-model", api_request_id="new-request",
            ended_at=2, usage={"prompt_tokens":20, "output_tokens":3, "total_tokens":23},
        )

        old_model = broker.usage_snapshot("session-one", "old-model")
        self.assertNotIn("inputTokens", old_model)
        self.assertEqual(old_model["sessionTotalTokens"], 35)
        self.assertEqual(broker.usage_snapshot("session-one", "new-model")["inputTokens"], 20)

    async def test_delayed_older_model_response_cannot_replace_latest_request(self):
        broker = LinkActivityBroker()
        broker.bind_link_session("session-one", "link-one")
        broker.record_api_usage(
            session_id="session-one", model="new-model", api_request_id="new-request",
            ended_at=20, usage={"prompt_tokens":20, "output_tokens":3,
                                "cache_read_tokens":15, "total_tokens":23},
        )
        broker.record_api_usage(
            session_id="session-one", model="old-model", api_request_id="old-request",
            ended_at=10, usage={"prompt_tokens":10, "output_tokens":2,
                                "cache_read_tokens":7, "total_tokens":12},
        )
        # Per-model dedupe still rejects a replay of the delayed response.
        broker.record_api_usage(
            session_id="session-one", model="old-model", api_request_id="old-request",
            ended_at=10, usage={"prompt_tokens":999, "output_tokens":999,
                                "cache_read_tokens":999, "total_tokens":999},
        )

        new_model = broker.usage_snapshot("session-one", "new-model")
        self.assertEqual(new_model["inputTokens"], 20)
        self.assertEqual(new_model["cachedTokens"], 15)
        self.assertEqual(new_model["sessionInputTokens"], 30)
        self.assertEqual(new_model["sessionOutputTokens"], 5)
        self.assertEqual(new_model["sessionCachedTokens"], 22)
        self.assertEqual(new_model["sessionTotalTokens"], 35)
        old_model = broker.usage_snapshot("session-one", "old-model")
        self.assertNotIn("inputTokens", old_model)
        self.assertNotIn("cachedTokens", old_model)
        self.assertEqual(old_model["sessionTotalTokens"], 35)

    async def test_reset_clears_latest_request_order_watermark(self):
        broker = LinkActivityBroker()
        broker.bind_link_session("session-one", "link-one")
        broker.record_api_usage(
            session_id="session-one", model="new-model", api_request_id="new-request",
            ended_at=20, usage={"prompt_tokens":20, "total_tokens":20},
        )

        broker.reset_api_usage(session_id="session-one")
        broker.record_api_usage(
            session_id="session-one", model="old-model", api_request_id="old-request",
            ended_at=10, usage={"prompt_tokens":10, "total_tokens":10},
        )

        usage = broker.usage_snapshot("session-one", "old-model")
        self.assertEqual(usage["inputTokens"], 10)
        self.assertEqual(usage["sessionTotalTokens"], 10)

    async def test_reconnect_preserves_deduplicated_totals_and_reset_clears_the_family(self):
        broker = LinkActivityBroker()
        broker.bind_link_session("parent-session", "visible-link")
        broker.publish_subagent_lifecycle(
            "subagent_start", None,
            {"parent_session_id": "parent-session", "parent_turn_id": "parent-turn",
             "child_session_id": "child-session"}, occurred_at=1,
        )
        payload = dict(
            session_id="child-session", model="child-model", turn_id="child-turn",
            api_request_id="child-request", api_call_count=1, ended_at=2,
            usage={"prompt_tokens":100, "output_tokens":5,
                   "cache_read_tokens":0, "total_tokens":105},
        )
        broker.record_api_usage(**payload)
        await broker.attach(lambda _: asyncio.sleep(0))
        await broker.detach()
        broker.bind_link_session("parent-session", "visible-link")
        broker.record_api_usage(**payload)

        self.assertEqual(
            broker.usage_snapshot("parent-session", "unseen-parent-model"),
            {"sessionInputTokens": 100, "sessionOutputTokens": 5,
             "sessionCachedTokens": 0, "sessionTotalTokens": 105},
        )
        broker.reset_api_usage(session_id="parent-session")
        self.assertIsNone(broker.usage_snapshot("parent-session", "unseen-parent-model"))

    async def test_child_usage_updates_session_total_without_becoming_parent_context_occupancy(self):
        broker = LinkActivityBroker()
        received = []

        async def sender(payload):
            received.append(payload)

        broker.attach_context_provider(lambda _: {
            "model": "parent-model", "contextUsed": 27_903, "contextMax": 922_000,
            "contextPercent": 3, "compressions": 0, "isCompacting": False,
        })
        await broker.attach(sender)
        try:
            broker.activate("parent-session", "parent-turn", link_session_id="visible-link")
            broker.publish_subagent_lifecycle(
                "subagent_start", "visible-link",
                {"parent_session_id": "parent-session", "parent_turn_id": "parent-turn",
                 "child_session_id": "child-session"}, occurred_at=1,
            )
            broker.record_api_usage(
                session_id="child-session", model="child-model",
                turn_id="child-turn", api_request_id="child-request",
                usage={"prompt_tokens": 10_000, "output_tokens": 100,
                       "cache_read_tokens": 9_000, "total_tokens": 10_100},
            )
            await asyncio.sleep(0.05)
            context = [item for item in received if item.get("type") == "session.context"][-1]
            self.assertEqual(context["contextUsed"], 27_903)
            self.assertEqual(context["contextPercent"], 3)
            self.assertNotIn("inputTokens", context)
            self.assertEqual(context["sessionTotalTokens"], 10_100)
            self.assertIs(context["sessionIncludesSubagents"], True)
        finally:
            await broker.detach()

    async def test_duplicates_stale_requests_and_reset_preserve_session_boundaries(self):
        broker = LinkActivityBroker()
        broker.bind_link_session("canonical-session", "visible-link")
        broker.bind_link_session("retained-alias", "visible-link")
        broker.record_api_usage(session_id="canonical-session", model="model",
            turn_id="turn", api_request_id="request-2", api_call_count=2,
            usage={"prompt_tokens":100,"cache_read_tokens":80})
        for request_id, count in (("request-2", 2), ("request-1", 1)):
            broker.record_api_usage(session_id="canonical-session", model="model",
                turn_id="turn", api_request_id=request_id, api_call_count=count,
                usage={"prompt_tokens":999,"cache_read_tokens":999})
        self.assertEqual(broker.usage_snapshot("canonical-session", "model")["cachedTokens"], 80)
        self.assertEqual(broker.bound_link_session("canonical-session"), "visible-link")
        broker.record_api_usage(session_id="canonical-session", model="model",
            turn_id="turn", api_request_id="request-3", api_call_count=3, usage=None)
        self.assertIsNone(broker.usage_snapshot("canonical-session", "model"))
        broker.record_api_usage(session_id="canonical-session", model="model",
            api_request_id="request-4", usage={"prompt_tokens":True})
        self.assertIsNone(broker.usage_snapshot("canonical-session", "model"))
        broker.reset_api_usage(session_id="canonical-session")
        self.assertIsNone(broker.usage_snapshot("canonical-session", "model"))
        self.assertEqual(broker.bound_link_session("retained-alias"), "visible-link")

    async def test_hook_usage_reaches_existing_context_wire_fields(self):
        broker = LinkActivityBroker()
        received = []

        async def sender(payload):
            received.append(payload)

        broker.attach_context_provider(lambda _: {
            "model": "fixture-model", "contextUsed": 0, "contextMax": 10000,
            "contextPercent": 0, "compressions": 0, "isCompacting": False,
        })
        await broker.attach(sender)
        try:
            broker.activate("hermes-session", "turn-1", link_session_id="link-session")
            broker.record_api_usage(session_id="hermes-session", turn_id="turn-1",
                api_request_id="request-1", api_call_count=1, model="fixture-model",
                usage={"input_tokens":11, "output_tokens":7, "cache_read_tokens":200,
                       "cache_write_tokens":300, "reasoning_tokens":2,
                       "prompt_tokens":511, "total_tokens":518},
                response={"private": "MUST-NOT-LEAK"})
            broker.publish_context_window("hermes-session", "turn-1", force=True)
            await asyncio.sleep(0.05)
            payload = [x for x in received if x.get("type") == "session.context"][-1]
            self.assertEqual(payload["contextUsed"], 511)
            self.assertEqual(payload["inputTokens"], 511)
            self.assertEqual(payload["outputTokens"], 7)
            self.assertEqual(payload["cachedTokens"], 200)
            self.assertEqual(payload["totalTokens"], 518)
            self.assertEqual(payload["sessionInputTokens"], 511)
            self.assertEqual(payload["sessionOutputTokens"], 7)
            self.assertEqual(payload["sessionCachedTokens"], 200)
            self.assertEqual(payload["sessionTotalTokens"], 518)
            self.assertIs(payload["sessionIncludesSubagents"], True)
            self.assertNotIn("MUST-NOT-LEAK", str(received))
        finally:
            await broker.detach()

    async def test_usage_absence_and_other_session_cannot_invent_counters(self):
        broker = LinkActivityBroker()
        broker.bind_link_session("session-one", "link-one")
        broker.record_api_usage(session_id="session-one", model="fixture-model",
                               api_request_id="request-one", usage=None)
        self.assertIsNone(broker.usage_snapshot("session-one", "fixture-model"))
        broker.record_api_usage(session_id="session-one", model="fixture-model",
                               api_request_id="request-two", usage={
                                   "prompt_tokens":12,"output_tokens":2,"total_tokens":14,
                                   "cache_read_tokens":0})
        self.assertIsNone(broker.usage_snapshot("session-two", "fixture-model"))
        self.assertIsNone(broker.usage_snapshot("session-one", "different-model"))
        self.assertEqual(broker.usage_snapshot("session-one", "fixture-model")["cachedTokens"],0)


if __name__ == "__main__":
    unittest.main()
