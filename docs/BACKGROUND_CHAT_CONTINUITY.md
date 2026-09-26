# Background chat continuity

Loopdy uses iOS's existing `remote-notification` wake capability. Background execution is discretionary: silent pushes may be delayed, combined, or omitted; force-quit prevents background relaunch until the app is opened again. There is no audio/VoIP/location keepalive and no guarantee the phone stays current while suspended.

## Preserve content, defer presentation

Foreground presentation also follows the
[Chat interaction contract](CHAT_INTERACTION_CONTRACT.md). Catch-up must preserve
reader ownership, native input, disclosure choices, and request-scoped drafts.
Coalescing presentation or persistence must not discard canonical events or
reintroduce delayed scrolling that overrides a drag. Keep the existing lifecycle
flushes when changing tool-event checkpoint frequency.

```text
signed encrypted frame
  -> normal authenticated decode and event handling
  -> canonical items/activity + existing protected local persistence
  -> one accumulated transcript projection when catch-up finishes
```

The app does not discard activity, generated cards, drafts, or terminal messages in expectation of a later history fetch. Existing request continuations, approval handling, sender/session checks, receipt order, and account boundaries remain intact. Route-owned chat models defer their derived transcript presentation; Home, sidebar and Sessions likewise hold a stable catalog presentation until catch-up ends. Routing and actions continue to resolve canonical session state. Canonical item and activity mutations are still applied, and persistence remains coalesced while presentation is deferred. Never force a full catalog write per catch-up event. A newly prepared chat inherits the current presentation boundary. Closing the boundary rebuilds its transcript once and flushes the shared catalog after the model snapshots, preserving source ordering and consolidated tool groups. Suspension and background-wake completion likewise flush all dirty conversations together. Queued final answers also defer automatic Home reloads to one refresh at catch-up completion; see [idle startup reliability](IDLE_STARTUP_RELIABILITY.md).

The presentation boundary is idempotent rather than an accumulating nesting counter. Backgrounding opens it synchronously before reconnect can deliver queued frames. Foreground recovery uses the existing authenticated account/socket refresh and a bounded drain before revealing accumulated transcript state. It does not issue another history fetch that could overwrite newer live output. Existing catalog/hydration logic still owns cold-open history recovery.

## Runtime budget

A silent wake has a default 20-second transport budget beginning before connection establishment, rather than two separate connection and drain budgets. The normal quiet window is 500 milliseconds after at least two seconds. Foreground recovery uses a shorter maximum three-second drain with a 150-millisecond quiet window. Expiry, cancellation, and failure close wake-owned presentation boundaries. Account reset also releases the old boundary.

These are application limits, not an entitlement to iOS runtime. Local flush work and system scheduling are not hard real-time operations. When network recovery fails, the existing connection error remains visible and the app retains its cached data; it does not claim to show current server state. If a backlog cannot be drained in the bounded foreground window, later arrivals continue through the normal live path.

## Host reduction

The Loopdy plugin limits assistant draft presentation frames to one per 250 milliseconds per active turn. Intermediate text snapshots may be coalesced. Final responses are complete and unthrottled, and tool, approval, attachment, and canonical history records are not coalesced away. This uses the existing encrypted Link transport, with no new plaintext cloud cache or Hermes core change.

## Verification boundary

Focused checks exercise a 75-message deferred presentation batch with local persistence, wake timeout including connection establishment, encrypted notification delivery/receipt, idempotent presentation boundaries, and retained native chat scrolling. Physical APNs scheduling and microphone acoustics are not simulator guarantees. They are not release gates for this work.
