# AGENTS.md: working on the bighelp iPhone app

This guide is for AI agents and people picking up work on bighelp. It covers how we work, where things live, and the
traps that have already cost us time. Read it before you change anything. Some things apply only to the maintainer's
own checkout: if `docs/MAINTAINER_NOTES.md` exists, it covers releases, the maintainer's hosts and private services.
It isn't in the public mirror.

## What bighelp is

bighelp is a native iPhone, iPad and Vision Pro app (plus Watch, widgets, Live Activities and Shortcuts) for personal AI agents running
on [Hermes](https://github.com/NousResearch/hermes-agent). It should feel like texting a friend, not like running a
server. The app talks straight to the user's own Hermes host. There's no bighelp account.

The companion Hermes plugin lives in [bighelp-plugin](https://github.com/promptclickrun/bighelp-plugin). It adds the
extras: Feed/Ideas/Goals, cards, live voice, provider usage, secure input, and notifications. Many features need a
change in both repos.

## Mindset

- **Simple for normal people.**
  - Everyday screens use plain words and short sentences.
  - Anything that looks like host administration goes behind Settings › Nerd Mode: files, gateways, plugins, MCP,
    logs, raw IDs, token counts. Nerd Mode is `settings.nerdModeEnabled`, also the `nerdModeEnabled` environment
    value.
  - Everyday controls must never live only behind Nerd Mode.
- **One place for each thing.**
  - There's one ☰ menu (`BighelpMenu`) and one Settings.
  - Don't add a second menu, drawer or settings copy for a feature. Add a row where people already look.
  - Never show "bighelp account" or "Link" wording. That pairing system is retired.
- **Real data only.**
  - Avatars, activity poses and badges must come from what the agent is actually doing.
  - Never fake progress.
- **No AI spending by default.**
  - Feed, Ideas and Goals start empty, with no default scheduled jobs.
  - Content appears only after the user asks their agent for it.
- **Protect the chat.** The accepted chat behavior is a contract: [docs/CHAT_INTERACTION_CONTRACT.md](docs/CHAT_INTERACTION_CONTRACT.md).
  New looks must not break scrolling, drafts, streaming, keyboard control or history.
- **Reproduce first, then fix the root cause.**
  - Write the failing test before the fix, and make sure it fails without the fix.
  - Fakes must behave like the real host. For example, Hermes answers `prompt.submit` with `streaming`, not `queued`.
    A fake that says `queued` hid a real bug.
- **Verify what you ship.**
  - Run it, look at screenshots in light and dark mode, and use the real controls.
  - Say which evidence came from demo fixtures, which from a real host, and which from a device.
  - Don't call something done without proof.
- **Keep it focused and tidy.**
  - Match the surrounding code, naming and comment density. Comments explain why, not what.
  - Remove temporary files, simulators, proxies and background processes you started.
- **This repo is public.** Never put a real person's data, hosts, balances or plans in code, tests, docs, issues or
  screenshots. Use made-up numbers.

## Where things live

| Path | What it is |
|---|---|
| `Bighelp/App/` | App composition, `RootShellView`, routes (`AppRoute`, `RootDestinations`), ☰ menu, connection keeper, widget/Shortcut entry points |
| `Bighelp/Chat/` | Chat screen, composer, `ChatModel` (+ `ChatModel+Submission`), the native chat timeline |
| `Bighelp/DirectHermes/` | The Hermes client: sign-in, WebSocket JSON-RPC, dashboard REST, plugin routes (`DirectHermesNativeContext.swift`), access credentials |
| `Bighelp/Workspace/` | `WorkspaceOperation` (every host operation) and workspace stores |
| `Bighelp/Settings/` | Settings screens and `SettingsStore` |
| `Bighelp/Agents/`, `Board/`, `Companion/` | Agents, Feed/Ideas/Goals, the avatar kit renderer |
| `Bighelp/Usage/` | Provider Usage overlay, store and settings |
| `Bighelp/Voice/` | Turn-based and live voice |
| `Bighelp/Spatial/` | Vision Pro: the agent in the room (`SpatialAvatarModel`, its volume and voice panel, its Settings section) |
| `Bighelp/DesignSystem/` | `BighelpTheme`, `BighelpTokens`, glass surfaces, fonts, provider logos, `BighelpDeferredSection` |
| `Bighelp/Hosts/`, `Bighelp/LiveActivity/`, `Bighelp/Notifications/`, `Bighelp/Shortcuts/` | Host setup, Live Activities, notifications, App Intents |
| `BighelpTests/` (Swift Testing), `BighelpUITests/` (XCUITest) | Tests. The UI test base class `BighelpUITestCase` is in `ReferenceHubUITests.swift` |
| `BighelpVisionUITests/` | Vision Pro UI tests, run with the `BighelpVision` scheme |
| `Scripts/` | Real-host probes, logo export, CI helpers, public mirror publishing |
| `Design/AvatarKit/` | Source of the avatar characters (`tools/build.py`, `tools/export_native.py`) |
| `docs/` | Contracts and deep dives. Start with `ARCHITECTURE.md`, `NATIVE_TRANSPORT.md`, `DEVELOPMENT.md` |

`DESIGN.md` is the visual and navigation authority, and `PRODUCT.md` covers product direction.

## Build and test

- `project.yml` is the source of truth. Run `xcodegen generate` after adding, moving or removing files, and commit
  the regenerated `Bighelp.xcodeproj`. Never hand-edit the `.pbxproj`.
- The app needs Swift 6 and supports iOS 17 and later, and visionOS 26 and later. Keep Swift 6 concurrency
  correct.
- Unit tests use Swift Testing and UI tests use XCUITest. Run the smallest relevant suite while you iterate.
- **Demo mode:** `-use-demo-fixtures -disable-demo-delays` runs the app with sample data and no host. Fixture clients
  are in `Bighelp/App/AppFixtureClients.swift` and `AppFixtureSetup.swift`. New host features need a demo client too,
  so UI tests and screenshots work without a host.
- **Simulators:**
  - Never run two `xcodebuild test` sessions on one simulator.
  - Give parallel builds their own `-derivedDataPath`.
  - Run long suites in the background so you can keep working.
- **Known failures:** some tests fail on untouched `main` too, for example
  `DirectHermesVoiceMediaTests.nativePCMSilenceActuallySchedulesAndDrains` (simulator audio) and a few old UI tests.
  Check against `main` before calling something a regression.

### UI test traps

- `BighelpUITestCase` launches with Nerd Mode on and `-loopdy.home.opens-chat NO`. Use its helpers:
  - `openRootTab`
  - `settingsRow`
  - `openChatInfo`
  - `chatNewChatButton`
- Launch arguments pin `@AppStorage` values for the whole run, and taps in the UI can't change them. A `NO` launch
  argument is a string, so read flags with `UserDefaults.bool(forKey:)`.
- `app.buttons["x"]` matches accessibility identifiers. SwiftUI menu items use their title as the identifier.
- An `.accessibilityIdentifier` on a container hides its children's identifiers unless the container also has
  `.accessibilityElement(children: .contain)`.
- Chat message text is a text view (`chat.message.inline-selection`). `staticTexts` queries never match it, so a
  "must not show" check written that way passes without testing anything.
- Uninstalling the app from the simulator clears microphone permission.
- Password prompts from iOS can appear late and cover the screen.

## Architecture intricacies

### Talking to Hermes

- **How chat connects:** chat is native Hermes only, over the dashboard's WebSocket JSON-RPC gateway. The plugin's
  routes sit under `/api/plugins/loopdy/native/…`. See [docs/NATIVE_TRANSPORT.md](docs/NATIVE_TRANSPORT.md).
- **Server requests handshake:** send `client.capabilities {server_requests: true}` on every socket, after the
  handlers are registered and again after each reconnect. Without it, Hermes answers clarify, approval, secret and
  sudo requests itself, with blanks, and the prompts never show. `advertiseServerRequests()` in
  `DirectHermesNetworking.swift` does this.
- **A turn stays pending while it streams:** after `prompt.submit` returns `streaming`, the chat isn't "ready for a
  new turn" until the turn ends. A mid-turn Send must go through the steer/queue path (`sendMidSession`). Steer is
  the default.
- **Plugin routes:**
  - Each route is a `WorkspaceOperation` case plus a `Route(path:feature:isMutation:maximumResponseBytes:)` in
    `DirectHermesNativeContext.swift`.
  - The route only runs when `/native/context` lists its feature. Otherwise it fails as unsupported, and the UI
    should say "update the plugin", never show a raw error.
  - Requests send `If-Match` (the context ETag) and `X-Loopdy-Request-ID`, which must be a lowercase UUID.
  - On a `conflict` (context changed), reload the context and retry once.
- **Plugin pin:**
  - Info.plist `BighelpNotificationPluginVersion` and `BighelpNotificationPluginRevision`, and the plugin `ref` in
    `.github/workflows/ios-ci.yml`, must all name the same merged plugin commit.
  - Bump all three together whenever the app needs a newer plugin.
  - The in-app plugin updater installs exactly that revision.
- **Supported Hermes versions:** 0.21.2 to 0.21.5.
  - Hosts differ, so parse leniently: ignore unknown keys and treat most parts as optional.
  - A missing part should hide one row, not break a screen.

### SwiftUI traps we've hit

- **Environment doesn't reach pushed screens:** values set on `RootShellView` or the NavigationStack root don't
  reach pushed screens (chats from `navigationDestination`, Settings `NavigationLink`s). Pass them at the push site.
- **Root `.task(id:)` pauses:** it doesn't restart while a chat covers the root. Connection upkeep lives in
  `WorkspaceConnectionKeeper`, injected per chat route.
- **`@ObservationIgnored` never refreshes views:** if a menu depends on something like "is a client configured",
  expose an observed flag.
- **A `.sheet` on `EmptyView()` never presents:** hang sheets on
  `Color.clear.allowsHitTesting(false).accessibilityHidden(true)`.
- **Presentation order:** close a popover before presenting a full-screen cover from it.
- **Glass button taps:** glass buttons need `.contentShape` before `bighelpNavigationGlass`, or taps miss.
- **Overlays that swallow taps:** full-screen `UIView` helpers in overlays need `isUserInteractionEnabled = false`,
  or they swallow every tap.
- **Chat row environment:** chat rows (`NativeChatTimeline`) copy selected environment values into each row. If a row
  acts stale (for example, animations frozen because it still thinks the app is inactive), check what the timeline
  copies and whether the representable reads it.
- **Type-checker timeouts:** very large `body`s (`RootShellView`, `BighelpApp`) time out the type checker. Pull
  pieces out into functions or named `ViewModifier`s.
- **Text styling:** styled text in the composer must pass attributes and theme colors. Plain `String` replacements
  lose them.

### Crashes that only happen on a real iPhone

Release builds on iPhone have a 1 MB main-thread stack, and the simulator has 8 MB. Big screens with many inlined
sections can crash only on devices ("Thread stack size exceeded").
- Wrap large screen sections in `BighelpDeferredSection`.
- Before shipping a big new screen, run `ReleaseScreensWalkthroughUITests`. It's a Release build linked with
  `-Wl,-stack_size,0x100000` that walks real onboarding through a password proxy. The test file explains its
  environment variables.

### iPad layout

- iPad has no always-open sidebars. ☰ opens the one menu, which slides in from the leading edge
  (`HomeMenuPresentation`); iPhone shows the same menu as a sheet. The bottom tab bar shows on iPad too.
- The chat lane (messages, message box, status rail) is `ChatCanvasLayout.regularLaneMaximumWidth` wide on iPad
  and Vision Pro. Bubbles take their share of it; don't reintroduce a fixed narrow column.

### Vision Pro

- The app target builds natively for visionOS (`supportedDestinations`), not as the iPad app in a window. Every
  change must build for both: `xcodebuild -destination 'generic/platform=visionOS Simulator'`.
- visionOS lacks Live Activities, widgets, haptics, apps' camera access, keyboard-dismiss-on-scroll and iOS 26's
  `glassEffect`. Use the shims in `BighelpPlatform.swift` and `#if os(visionOS)`. `if #available(iOS 26, *)` is
  true on visionOS, so it doesn't fence off iOS-only APIs.
- visionOS has its own layered app icon, `AppIconVision.solidimagestack` (the iPhone icon's art split into a
  cream back layer and the orb). Update it when the app icon changes; uploads without it are rejected.
- WebRTC comes from LiveKit's package on visionOS. Its Objective-C names carry an `LK` prefix, mapped back in
  `WebRTCVisionNames.swift`.
- Extra windows need multiple scenes, which only the visionOS Info.plist turns on (generated keys in
  `project.yml`). Conditional settings need both `[sdk=xros*]` and `[sdk=xrsimulator*]`; the first doesn't match
  the simulator.
- An app-wide `.tint` fills every toolbar button with that color on visionOS, so there's none there.
  `theme.canvas` is a light tint so windows stay glass.
- The agent in the room (`Bighelp/Spatial/`) talks through `BighelpShortcutService.connectedWorkspace()`, the same
  host path as Shortcuts. Apps can't move windows themselves: people move the volume with the system bar under it,
  and visionOS remembers the spot and snaps it to tables.
- Vision Pro UI tests: `XCUIScreen` screenshots come back blank, so tests ask the Mac for `simctl io` screenshots
  (see `SpatialAvatarUITests`). `app.swipeUp()` fails with several windows open; swipe the list instead. The speech
  permission can't be pre-granted, and an unanswered prompt comes back on every launch, so reset privacy and reboot
  the simulator before a run.

### Connections, widgets and Shortcuts

- The app closes its host connection in the background. A suspended runtime can still report "ready".
- Shortcuts and widgets first check that the host answers, and reconnect once if it doesn't.
- An incoming widget or link tap during startup is queued until the host runtime is ready.
- Returning to a chat reloads it from the host. Treat the host's saved history as the truth after a turn ends.

### Names that must stay "loopdy"

The app was first called Loopdy. The code now says bighelp, but these are stored on phones or used by other systems.
Renaming them would sign people out or break widgets, Shortcuts, pushes or the plugin:
- bundle IDs, app groups and keychain groups (`app.loopdy.*`)
- lowercase settings keys and launch arguments (`loopdy.*`, `-loopdy.*`)
- keychain services and on-device folder names (`Loopdy…`)
- widget kinds (`Loopdy*Widget`)
- `LoopdySessionActivityAttributes`
- Shortcuts types (`SendLoopdyChatIntent`, `StartLoopdyVoiceChatIntent`, `LoopdyShortcut*`)
- the saved card key `"loopdyCard"`
- `X-Loopdy-Request-ID` and `x-loopdy-*` headers
- the plugin id, routes and CLI (`loopdy`, `/api/plugins/loopdy`, `hermes loopdy`)
- the `loopdy://` URL scheme and the `*.loopdy.app` domains

New code uses Bighelp names. Don't "finish" the rename on this list.

### Provider logos

- Logos are bundled SVGs in `Bighelp/Resources/Assets.xcassets/ProviderLogo*.imageset`.
- To add one:
  - Add it to `APPROVED_NAMES` in `Scripts/publish-provider-logos.py`.
  - Record it in `ProviderLogos-PROVENANCE.md` and `ProviderLogos-NOTICES.txt`.
  - Add an `AIProviderBrand` case.
  - Update the lists in `ProviderAssetTests`.
- The SVG exporter is strict. Remove `<title>`, CSS classes and em sizes. Use a 512×512 canvas, since export
  rasterizes at the SVG's own size. Write arc flags with separators (`a4 4 0 0 1 2 3`), because Apple's renderer
  misreads compact flags.
- Logos must have transparent backgrounds. Only use art we have the right to ship.
- Older app builds reject a remote logo manifest that contains names they don't know, so a new logo always needs an
  app build as well.

### Avatars and art

- The avatar kit's source is `Design/AvatarKit`. `tools/export_native.py` writes `Bighelp/Resources/AvatarKit.json`,
  which the app draws natively.
- Only first-party or permissively licensed art can ship in this Apache-2.0 repo.
- The maintainer approves new character art before it ships.

### Secrets and access

- Credentials live in the Keychain, never in `UserDefaults` or logs.
- Proxy custom headers have their own Keychain service and a list of reserved header names they can't use.
- `Config/Local.xcconfig` (team ID, keys) is git-ignored. See `Config/Local.xcconfig.example`.
- Keep all external input bounded and validated.

## Testing against a real Hermes host

- `Scripts/HostSignInMatrixProbe.py` starts isolated Hermes hosts for the sign-in matrix. Its `--modes tools
  --plugin <plugin checkout>` option runs scripted tool turns for secure input, steering and questions
  (`HostSignInMatrixUITests`).
- `Scripts/NativeWorkspaceAcceptanceProbe.py` covers the workspace and chat acceptance flows.
- **Never start Hermes with a fresh `HERMES_HOME` against a shared Hermes checkout.** Hermes treats it as an
  unfinished update, rebuilds the checkout and rewrites its launchers to point at your throwaway environment. Instead:
  - Use a separate clone of Hermes.
  - Set `HERMES_DISABLE_LAZY_INSTALLS=1`.
  - Fingerprint the real install's launchers before and after.
- Test hosts need `plugins.enabled: [loopdy]`, or user plugins don't load.
- Never call `/api/gateway/restart` on a test host. On macOS it reaps every gateway process on the machine.
- Ask the maintainer before running anything against their real hosts.

## Git, commits and releases

- **Commits:**
  - Keep them small and logical.
  - The subject says what changed for the user, in plain words, for example "Send during a running tool steers the
    turn" or "Widget New Chat waits for the host instead of failing".
  - Commit your work before you stop.
- **Pull requests:**
  - Explain the visible behavior and any trust-boundary impact.
  - List what you tested, and where: demo, real host or device.
  - The maintainer merges.
- **Versions** live in `project.yml`: `MARKETING_VERSION`, and `CURRENT_PROJECT_VERSION` in every target. Regenerate
  after bumping.
- **TestFlight "What to Test" notes** are plain text. Some symbols (like ☰) are rejected. Write them for testers:
  - new features
  - bug fixes
  - anything they need to do, like updating the plugin
- The public mirror is made from committed files by `Scripts/publish-public.py`, which only the maintainer runs. It
  leaves out private paths and refuses to publish mentions of private infrastructure.
