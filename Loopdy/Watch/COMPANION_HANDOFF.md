# Watch companion V2 integration contract

The details below describe the Watch companion's interface contract.

## Required parent composition wiring

In `Loopdy/App/LoopdyApp.swift`, replace the bridge construction with:

```swift
let watchApprovalBridge: LoopdyWatchApprovalBridge? = usesFixtures
    ? nil
    : LoopdyWatchApprovalBridge(loader: pluginClient, client: pluginClient)
```

Replace the existing `watchApprovalBridge?.configure(...)` with:

```swift
watchApprovalBridge?.configure(
    featureStore: featureStore,
    sessionCatalog: sessionCatalog,
    agentDirectory: agentDirectory,
    authority: { [weak linkAccount, weak linkSocket] in
        guard let linkAccount, linkAccount.state == .ready,
              let credentials = linkAccount.credentials else {
            return WatchPhoneAuthority(scope: nil, link: .signedOut)
        }
        guard let hostID = hostRepositoryScope.hostID else {
            return WatchPhoneAuthority(scope: nil, link: .unavailable)
        }
        return WatchPhoneAuthority(
            // LOCAL ONLY; the bridge persists a digest and sends only a random UUID.
            scope: "\(credentials.deviceID):\(credentials.authorizationEpoch):\(hostID)",
            link: linkSocket?.connectionState == .verified ? .connected : .connecting
        )
    },
    reconnect: { [weak linkSocket] in await linkSocket?.retryConnection() },
    voiceClient: voiceClient
)
```

The existing `publish(loaded)` callback and sign-out/account-deletion `clear()` calls remain. Call `clear()` at the start of the host-switch cleanup transaction, before changing the scoped stores, too; the scope closure subsequently rotates the authority as a second fence. Use the *loaded repository scope*, not an optimistic host picker selection. Do not let a new non-nil scope become visible while old scoped stores remain populated.

The default authority is deliberately unavailable and voice factory nil: until wiring is applied, Watch actions fail closed. The old initializer's enrollment closure is accepted only for source compatibility and is never invoked. No RootShell changes are required. The production `pluginClient` also supplies `DashboardDataSource` and `DashboardClarificationClient`; decision revalidation calls those directly because DashboardModel intentionally swallows refresh failures and retains stale rows. Test doubles must implement those protocols for attention/approval action paths.

## Target membership / manifest

Existing XcodeGen folder globs already cover the new files. Parent must regenerate the project; no manifest or pbx edits were made here.

- **Both iOS + Watch:** `LoopdyWatchShared/WatchCompanionProtocol.swift`, `WatchCompanionPersistence.swift`.
- **iOS only:** `Loopdy/Watch/WatchCompanionJournal.swift`.
- **Watch only:** `LoopdyWatch/WatchReplySpeech.swift`.
- `LoopdyWatch/Info.plist`: `WKRunsIndependentlyOfCompanionApp = false`.
- Existing WatchConnectivity, WatchKit and AVFoundation SDK frameworks suffice; no packages, background modes, microphone recorder or iOS Speech framework are introduced.
- Existing direct-client/enrollment/Keychain code remains dormant and may stay in target membership. The companion store never creates, reads, deletes or enrolls legacy keys.
- This Markdown file is documentation, not a Sources build-phase input.

## Protocol map

One property-list envelope, version **2**, key `loopdy.companion.v2`, maximum **60,000 bytes**, bounded collections/strings and duplicate-ID validation.

| Watch → iPhone | iPhone behavior / reply |
|---|---|
| `refresh(UUID, reconnect: Bool)` | Immediate current snapshot; coalesced refresh and optional existing Link retry. Connection success is shown only from actual Link state, never the callback. |
| `action(id, authorityID, offerID, createdAt, action)` | Reject stale/wrong-authority/non-offered/busy actions. Persist a pending receipt before acknowledging or submitting. |
| `status(requestID, authorityID)` | Read the same durable receipt; unknown/interrupted work is **unconfirmed**, not retried. |
| `selectSession(id)` action | Hydrate that phone session, then committed receipt and bounded transcript projection. |
| `dismissUpdate(id)` action | Only actual inbox updates can be dismissed; not a pretend resolution of Needs Attention. |
| `respond(itemID, text)` action | Re-fetch, compare the exact original offer/identity/expiry/choices; use existing clarification client and verify its event/request-correlated receipt. |
| `approve(requestID, decision)` action | Re-fetch dashboard and approval; require exact offered sender, policy, scope, event/session/agent identity and expiry. Existing client submits current request digest. |
| `voice(sessionID, text)` action | Existing injected phone VoiceSessionClient, no microphone or speech on phone. Guard authority after the await before any transcript write. Reply is committed only after the actual response. |

Snapshots use `updateApplicationContext` (replaceable latest state). They include random authority UUID, durable monotonic revision, offer UUID, coarse phone Link status and bounded presentation data. Terminal receipts use reachable messaging **and** `transferUserInfo`; the durable phone journal plus status lookup survives lost delivery/relaunch. Watch never queues or automatically retries consequential commands.

- Request/offer validity: 120 seconds, at most 30 seconds future clock skew.
- Watch refresh deadline: 10 seconds. Local waiting timeout: 100 seconds. Phone operation deadline: 110 seconds. Timeout/cancellation never claims a rollback.
- One phone action at a time. Journal: at most 128 receipts retained for 24 hours; fail closed on storage/capacity errors. Pending entries become unconfirmed after phone relaunch. Expired command timestamps prevent replays after journal expiry.
- Phone journal and Watch recovery are atomic, protected, backup-excluded Application Support files. Watch does not persist prompts or snapshots; it retains one bounded terminal receipt (including final voice reply) so delivery immediately before process termination is not lost. Receipt restoration is limited to 24 hours and account/host changes clear it. The phone journal also contains bounded final voice replies for recovery.
- Sign-out/host changes revoke in-memory offers, cancel old transfers/tasks and clear cached Watch state when the new context arrives. Previously displayed content cannot be remotely erased while Watch is disconnected; it becomes stale and actions are disabled.
- System dictation returns an editable draft; **Send** is separate. System input cancellation/back/background never submits. **Read reply aloud** is explicit foreground consent using watchOS AVSpeechSynthesizer; no automatic/background playback and no always-on capture.
- Multi-select/oversized clarification and incomplete approval disclosures point to iPhone rather than truncating permission semantics or faking completion.

## Parent validation / known boundary

No tests, builds, simulator runs or QA were authored/run by this child, as directed. Only source inspection, installed watchOS SDK declaration lookup and Git diff hygiene were performed. Parent should exercise codec rejection, pending-versus-committed behavior, replay fences, relaunch, late receipts, sign-out/host changes, exact approval revalidation, draft cancellation, dictation presentation and small/large/Dynamic Type Watch layouts. Prior direct-pairing fixture launch arguments no longer drive the production companion store; existing tests expecting independent Watch auth must be updated to the companion contract.

Hardware-only uncertainty: WatchConnectivity reachability/background transfer timing, native dictation language/permission availability and actual speaker/headphone routing. System Watch dictation follows Apple's settings and may have different processing/privacy behavior from the phone's on-device recognizer; review release privacy copy accordingly. No physical device is required to integrate the source; no physical or simulator proof is claimed here.
