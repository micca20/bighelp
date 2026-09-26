# Optional device-direct GitHub provider

This module implements two independent, user-initiated connection choices:
**device-code login** and **personal access token (PAT)**. Neither gates chat,
Scratchpad, Skills, Commands or Wiki. It does not wire the app/composer or prove
live authorization. Main owns integration, testing and acceptance.

## Configuration and public registration

PAT connection, saved-PAT selection and PAT discovery work with
`configuration: nil`. They never require a product client ID or an App installation.
Missing configuration disables only the device-code button, not GitHub as a whole.

Device-code login uses a verified Loopdy-owned GitHub App with device flow and
expiring user access tokens, exactly Metadata/Issues/Pull requests **read**
permissions, no Contents/organization/write permissions, no webhook/events.
The user-approved public registration was supplied in the task handoff:

- Client ID: `Iv23lixjYOwXssu6ryfg`
- Installation URL: `https://github.com/apps/loopdy-references/installations/new`

These are public configuration, not credentials. Main owns the Info.plist wiring
through `LoopdyGitHubClientID` and `LoopdyGitHubInstallationURL` and verifies it.
`GitHubConfiguration.from(bundle:)` returns nil when both keys are absent, throws
for partial/malformed configuration, and does not verify remote registration
ownership merely by validating string shape. Never substitute the numeric App ID,
a borrowed CLI client, a placeholder or a client secret.

Registration is not an installation, repository grant or user authorization.
No installation, credential issuance, real Keychain access or live OAuth/PAT call
was performed by this worker. Those retain their separate approval boundaries.

## Construction and connection contract

```swift
@MainActor
GitHubConnectionStore(
    ownerID: String?, configuration: GitHubConfiguration?,
    transport: any GitHubTransport = GitHubURLSessionTransport(),
    vault: any GitHubCredentialVault = GitHubKeychainVault(),
    clock: any GitHubClock = GitHubSystemClock()
)
GitHubConnectionView(store: GitHubConnectionStore)
```

Construction makes **zero network and zero vault calls** and starts in
`.disconnected`, even without configuration. No singleton, launch hook,
automatic selection, authorization or discovery is added. The connection view's
appearance reads only the local vault; its buttons initiate network operations.
The caller owns navigation and must not await GitHub before baseline catalogs or
ordinary sending. One production store owns this vault's refresh serialization;
do not create concurrent writers for the same owner/registration.

Connection methods are `@MainActor`:

- `connectPersonalAccessToken(_ token: String) async`: clear old selection/work,
  validate the exact input (reject whitespace, CRLF, controls, non-bearer alphabet
  or over 1,024 UTF-8 bytes; never trim it), GET `https://api.github.com/user`, then
  stage `.confirmAccount(identity)`. No vault read/save or selected identity is
  produced before confirmation. There is no prefix-derived identity, permission,
  expiry or token-type claim. Cancellation and owner/generation checks reject late
  results. The finite errors never reflect input/upstream diagnostics.
- `startConnection()`: existing device-code request/poll flow, pending/slow-down/
  expiry/denial handling, verified `/user`, then the same confirmation stage.
  Missing configuration affects only this method.
- `confirmAccount(userID: Int)`: validates the exact pending identity, owner/scope
  and device-token expiry, saves one atomic record, then selects it. Failed
  persistence drops pending credentials without selecting them.
- `cancelConnection()`: cancels unfinished setup and discards pending credentials;
  closing management does not disconnect a confirmed credential.
- `loadSavedIdentities()`: explicitly load local device and PAT namespaces; no
  network or automatic selection. Publishes the projections below.
- `selectCredential(id: String)`: select one exact saved record locally. This is
  the preferred per-chat selection API. Missing/invalid records fail closed.
- `selectIdentity(userID: Int)`: legacy compatibility; succeeds only when exactly
  one saved credential matches. Multiple credentials yield
  `.credentialSelectionRequired`, never first-match selection.
- `clearSelection()`, `setOwner(_:)`: cancel all provider work, clear private cache
  and selected credential; owner changes also hide saved projections. Invoke at
  the account boundary before exposing another owner's conversation.
- `disconnectCredential(id:) throws`: remove exactly one local record. Other
  credentials for the same GitHub account remain stored.
- `disconnect(userID:) throws`: legacy **identity-wide** removal of all that user's
  records in the available namespaces. Do not use for a single-credential UI row.
- `eraseOwnerCredentials() throws`: remove PAT and current configured device-flow
  namespaces **before** switching away from the account being deleted.

Observable credential-free projections are `savedIdentities: [GitHubIdentity]`
(deduplicated compatibility projection), `savedCredentials: [GitHubSavedCredential]`,
`selectedIdentity`, `selectedCredential`, `pendingOrigin`, `ownerID`, `configuration`,
`state`, and `generation: UUID`. A saved credential has `id: String`, `identity`,
`origin: GitHubCredentialOrigin` (`deviceFlow | personalAccessToken`) and a display
`label` with a non-token-derived PAT record suffix. The connection UI presents
separate rows/actions for multiple credentials belonging to the same GitHub user.
It clears secure-field input on verification, cancel, disappearance and generation
change; tokens never enter preferences or observable store projections.

State cases: `notConfigured` (device action only), `disconnected`, `requestingCode`,
`verifyingPersonalAccessToken`, `awaitingAuthorization(GitHubDevicePrompt)`,
`confirmAccount(GitHubIdentity)`, `connected(GitHubIdentity)`, `failed(GitHubError)`.
`GitHubIdentity` and `GitHubDeviceCode.decode(data:)` retain their existing APIs.
New errors are `invalidPersonalAccessToken`, `credentialSelectionRequired` and
`personalAccessTokenReplacementRequired`.

**Parent selection migration:** persist the explicitly chosen credential ID plus
immutable user ID under the local Loopdy-owner/chat context. Older user-only
selection may call `selectIdentity`; ambiguous matches require the user's choice.
At every chat/account switch, clear/select and reject old-generation results.
Provider reads still require the selected `userID`; they capture the exact current
credential generation. IDs/generations/owner bookkeeping are private local state,
never fields in outgoing references or history. Confirmation selecting a credential
in management does not implicitly assign it to every chat.

## Vault and credential migration

`GitHubTokenPair` and its initializer/decoder/validation remain unchanged. Only
its device-flow callers rotate refresh tokens. `GitHubCredentialRecord` now has
`id`, `origin`, `scope`, `identity`, `tokens: GitHubTokenPair?`,
`personalAccessToken: GitHubPersonalAccessToken?`, and `refreshPending`. Validation
requires exactly the credential fields matching the origin; a PAT has no invented
expiry, refresh token or refresh-pending state. Sensitive types redact normal/debug
description and reflection. Tokens are never sent to Link, agents, logs or exports.

Constructors:

```swift
GitHubCredentialRecord(scope:identity:tokens:refreshPending:) // retained device API
GitHubCredentialRecord(scope:identity:personalAccessToken:)   // new PAT record
try GitHubPersonalAccessToken(tokenString)
```

Legacy device records lacking `id`/`origin` decode as `.deviceFlow` with
`id = String(identity.id)`. Existing service prefix
`app.loopdy.github.user-tokens.v1.`, length-prefixed owner/client/host digest,
Keychain account and refresh-pending crash markers are preserved; no eager rewrite
or initialization migration occurs. The next confirmed device save/rotation writes
the explicit fields at the same key. Device records still require the corresponding
configured registration; no cross-registration adoption is attempted.

PAT scope is Loopdy owner + `github.com` + an **empty clientID sentinel**, distinct
from any valid App client ID; each confirmed PAT gets an independent UUID record
ID. Reconnecting a PAT adds a new record rather than overwriting a possibly
different resource-owner/repository scope. Remove the old row explicitly after
replacement. Tokens with the same account are never automatically coalesced.
Current-owner storage is bounded to 50 records across the available namespaces.
A configuration change cannot erase an unknown former registration namespace;
keep its configuration available until explicit cleanup if migrating registrations.

The synchronous `@MainActor GitHubCredentialVault` retains `records(in:)`,
`save(_:)`, `remove(userID:in:)`, `removeAll(in:)` and adds
`remove(recordID:in:)`. Production deletion uses the exact record key. The default
implementation supports legacy numeric device records only and **fails closed**
for PATs; parent memory vaults testing PAT deletion must implement the new method.
The concrete legacy `remove(userID:in:)` removes the numeric device record, not
all UUID PATs. Store-level identity-wide deletion enumerates exact records.

All records are atomic, non-synchronizing,
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, without a shared access group,
UserDefaults/file/cloud copy. Device refresh persists `refreshPending` before
rotation, verifies `/user` and replaces the pair atomically. Crash/ambiguous
rotation requires reconnect, never replaying a possibly consumed refresh token.
PATs bypass OAuth/refresh entirely. A 401 clears active selection/cache and reports
replacement required for PATs; the saved row remains available for explicit local
removal/replacement. A 403 can be policy/permission/SSO failure and does not pretend
to be token expiry. Local disconnect never claims remote revocation.

## Read-only provider and resolved resource identity

Existing read APIs remain:

```swift
func repositories(userID: Int, forceRefresh: Bool = false) async throws -> GitHubResourcePage
func search(kind: GitHubResourceKind, query: String, userID: Int,
            repositoryNames: [String]? = nil) async throws -> GitHubResourcePage
func lookup(kind: GitHubResourceKind, repository: String, number: Int? = nil,
            userID: Int, includeDescription: Bool = false) async throws -> GitHubResource
func revalidate(_ resource: GitHubResource, userID: Int,
                includeDescription: Bool = false) async throws -> GitHubResource
```

Device discovery retains `/user/installations` and eligible installation repository
pagination, exact App read-permission intersection and suspended-installation
exclusion. PAT discovery uses **`GET /user/repos`**, never installation endpoints.
GitHub documents this endpoint for fine-grained PATs with Metadata read permission.
It enumerates repositories the authenticated user can access as owner, collaborator
or organization member, within token access. It is not a universal public-repository
search. Fine-grained PATs have one resource owner; selected repositories, approval,
organization token policy and SSO can further constrain access. Neither a successful
`/user` call nor repository listing proves issue/PR permission or a read-only token.
Recommend fine-grained selected-repository read-only PATs. A classic or otherwise
overprivileged token retains its actual power despite this read-only client.

Both catalogs share the existing 60-second generation-bound metadata cache and
50-request/5,000-repository budget (device installation discovery additionally caps
at 10 pages). PAT pagination constructs numeric pages rather than following remote
Link URLs; duplicate IDs, page caps and throttling produce partial results. Missing
items in a partial catalog are unavailable, not proof of no access. Exact lookup
refreshes discovery and repository metadata before `/issues/{number}` or
`/pulls/{number}`. Discovery is bounded, not exhaustive permission attestation.

`GitHubResource`'s memberwise constructor now requires these fields, in order:

```swift
GitHubResource(kind: GitHubResourceKind, nodeID: String,
    repositoryID: String, resourceID: String, isResolved: Bool, isDraft: Bool,
    repository: String, number: Int?, title: String, url: URL,
    state: String, isPrivate: Bool, description: String?,
    descriptionTruncated: Bool, revision: String, fetchedAt: Date)
```

- `repositoryID`/`resourceID` are exact positive REST JSON decimal lexemes, not
  display numbers or GraphQL IDs. `GitHubJSON.decimalID()` rejects signs, zero,
  fractions/exponents and nonnumeric types; it never converts through Double/Int
  and permits up to 40 digits. Repository resources use the repository ID for both.
- `nodeID` remains the exact node identity. PR decimal/node IDs come only from
  **GET `/pulls/{number}`**, with base repository decimal/node/name validation;
  issue-shaped search IDs never masquerade as PR IDs.
- Catalog repositories and issue search rows have `isResolved == false`. PR search
  already performs exact lookup and returns resolved records. `lookup/revalidate`
  return resolved metadata and compare immutable decimal **and** node identities.
  **Only map a resolved resource to ReferenceSnapshot.** The preview revalidates
  before staging and never calls `onChoose` with an unresolved resource.
- `isDraft` is independent of `state`: PR state is `open`, `closed` or `merged`,
  including closed drafts. It is no longer overloaded as `state == "draft"`.
  Issues retain open/closed; repositories active/archived/disabled. `isPrivate`
  always comes from repository metadata, refreshed at exact lookup.
- `withoutDescription` and `hasSameContent(as:)` retain/compare all new identity,
  resolution, draft, privacy and state fields. Timestamp-only changes remain ignored.
  `revision` is GitHub's `updated_at`, not a checkout hash or attestation.
- Resource decoder methods retain existing arguments with an added defaulted
  `isResolved: Bool = true`; callers decoding discovery explicitly pass false.

Issue/PR title searches remain separate, repository-qualified, bounded to 20 repos,
one 30-item page per repo and 20 results. Empty issue/PR terms cause no search;
quotes, backslashes, controls and credential-shaped queries are rejected. Results
can be partial; raw search bodies reach the device but unused fields are discarded.
Descriptions are opt-in, bounded to 8 KiB at whole-character boundaries, with
credential-pattern redaction and visible truncation. No checkout/diff/reviews or
comments are silently included. Parent owns Send-time revalidation, content-change
confirmation, aggregate limits and exact historical snapshots.

## Transport and parent acceptance

`GitHubTransport`, `GitHubHTTPResponse`, the URLProtocol interception seam and
`GitHubClock` remain injectable. Production is ephemeral, cookie/cache/credential-
storage-free, fixed HTTPS GitHub origins and allowlisted GET/OAuth POST routes,
with pre-forwarding redirect rejection, exact response URL checks, timeouts and a
2 MiB response limit. Credentials only use headers or OAuth POST bodies, never URLs.
All requests share spacing/backoff and cancellation budgets. Production transport
requires JSON Content-Type on successful HTTP responses. The abstract response DTO
may omit that header (as the parent PAT probe does); supplied wrong MIME is rejected
and bounded strict JSON decoding remains mandatory. No test-specific token path is
present in production source.

No tests, build, QA or simulator were run by this worker. Parent tests were read and
left untouched. Main must verify compilation, the supplied zero-init/PAT confirmation
probe, memory-vault migration/deletion/ambiguity, cancellation/late responses/owner
switches, PAT no-refresh/no-installation behavior, device refresh regression, MIME/
redirect secrecy, malformed/large decimal IDs, actual PR identities, provisional
resolution, metadata preservation and the real iPhone/iPad controls. Live OAuth and
PAT acceptance require separately approved credentials and access; no fixture result
constitutes that approval or proof.

Authoritative contracts:
- https://docs.github.com/en/rest/repos/repos#list-repositories-for-the-authenticated-user
- https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-user-access-token-for-a-github-app
- https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/refreshing-user-access-tokens
