# Context usage reporting

Loopdy consumes Hermes's public `post_api_request` usage summary. The observer stores only bounded numeric token fields with session/model correlation, not prompts, response text, credentials, or raw provider payloads.

```text
provider -> Hermes canonical usage -> post_api_request
                                        |
                             bound session/model snapshot
                                        |
                          session.context + reconnect snapshot
```

The original client fields describe the **latest request**, not cumulative account usage:

| Field | Meaning |
| --- | --- |
| `contextUsed`, `inputTokens` | Full prompt input, including cached tokens |
| `outputTokens` | Output tokens |
| `cachedTokens` | Cache-read tokens |
| `totalTokens` | Full input plus output |

The additive cumulative fields describe this exact session plus every nested
subagent session whose public lifecycle start established immutable ownership:

| Field | Meaning |
| --- | --- |
| `sessionInputTokens` | Sum of full prompt input across accepted requests |
| `sessionOutputTokens` | Sum of output tokens |
| `sessionCachedTokens` | Sum of cache-read tokens |
| `sessionTotalTokens` | Sum of full input plus output |

`sessionIncludesSubagents: true` explicitly scopes these plugin-produced totals.
Native Hermes cumulative usage that cannot prove a child roll-up uses `false`,
and the app does not claim that those totals include subagents.

Finished children remain in the total. A nested child is visited once by session
ID, so its usage is not counted again through each ancestor. Child context
occupancy never replaces the parent `contextUsed`; that field remains the current
parent prompt window only. The app labels original fields “Latest …” and the new
fields “Session …”, with the total explicitly saying it includes subagents.

A real zero is retained. Missing or malformed latest usage is omitted rather than invented or summed with older requests. A cumulative bucket is omitted after any accepted request lacks that bucket, because a partial sum is not a session total. Duplicate request IDs and older same-turn request numbers cannot roll counts backward. Latest usage remains exact-session/model scoped; cumulative usage is exact owning-session scoped across models and its verified subagent tree. Chat alias bindings are preserved. Session reset clears the whole owned usage tree. Socket detach preserves bounded process-owned accounting so the same verified route can serialize it after reconnect; rebinding that Hermes session to a different Link route clears it.

Cache writes and reasoning tokens are tracked by Hermes, but the current native client schema does not expose separate rows for them. This contract does not claim account-wide quota reporting. Historical missing values are not reconstructed after a process restart.

## Verification

Focused usage, context, registration, activity, and wire-contract tests pass. The old test that injected a fictional `agent.token_usage` object now exercises a real broker with the supported hook shape.

A synthetic live repeated-prefix check passed through an installed Copilot adapter, unmodified Hermes, the public hook, this projector, and the existing `session.context` serializer. The second request reported 13,056 prompt tokens, 9 output tokens, 13,053 cache-read tokens, and 13,065 total tokens. The projected fields matched exactly. Its capture-only output sink did not send to a paired app; installation and visual activation remain separate deployment checks.

No Hermes private runtime mutation, provider-specific allowlist, raw prompt logging, or automatic service restart is introduced.
