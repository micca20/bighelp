# bighelp

bighelp is an iPhone app for your personal AI agents running on
[Hermes](https://github.com/NousResearch/hermes-agent). It makes working with
them feel like texting a friend.

## What it does

- **Chat** with your agents one-on-one or in group chats. Replies stream in live.
- **Avatars** that show what each agent is doing, like thinking, working or
  waiting on you. Design your own from 20 characters.
- **Voice** conversations, turn-based or live.
- **Approvals**, so an agent asks before it acts.
- **Tasks** that run on a schedule.
- **Feed, Ideas, Goals and Apps.** Your agent keeps these up to date, but only
  once you ask it to.
- **Rich replies.** Agents can send cards, forms, images and video.
- **Notifications, Live Activities, widgets, Shortcuts and an Apple Watch app.**
- **Themes** with light and dark modes.
- **Nerd Mode** for host tools like files, plugins and logs.

## How it works

- The app connects straight to a Hermes host you run, over your home network,
  Tailscale or HTTPS, and signs in with Hermes' own login. There's no bighelp
  account, and your chats go only between your phone and your host (plus the
  AI providers your host uses).
- The Hermes plugin [bighelp-plugin](https://github.com/promptclickrun/bighelp-plugin)
  adds the extras: notifications, live voice, cards and the Feed.

  ```sh
  hermes plugins install promptclickrun/bighelp-plugin --enable
  ```

- Push notifications and Live Activities are sent through
  [BuzzKit](https://buzzkit.dev).
- Sign-in details stay in the iPhone Keychain. There are no ads or analytics.
- Hermes behind Cloudflare Access, a password proxy, or a proxy that checks its
  own headers (like Pangolin) works too: see [docs/HOST_ACCESS.md](docs/HOST_ACCESS.md).

## Build it yourself

You need a Mac with a current Xcode (Swift 6) and
[XcodeGen](https://github.com/yonaskolb/XcodeGen). The app runs on iOS 17 or later.

```sh
brew install xcodegen
cp Config/Local.xcconfig.example Config/Local.xcconfig   # add your Apple Team ID
xcodegen generate
open Bighelp.xcodeproj
```

Run the **bighelp** scheme. bighelp was bighelp's original name, and the code
still uses it. `Config/Local.xcconfig` is git-ignored. Simulator builds work
with it empty. To run on a real iPhone, change the bundle IDs and app groups in
`project.yml` to ones your Apple team owns.

**No Hermes host?** Add these launch arguments to the scheme to use sample data:

```text
-use-demo-fixtures
-disable-demo-delays
```

**Tests:**

```sh
xcodebuild test -project Bighelp.xcodeproj -scheme Bighelp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## What's where

| Path | What it is |
|---|---|
| `Bighelp/` | The iPhone app |
| `BighelpWatch/` | The Apple Watch app |
| `BighelpLiveActivity/`, `BighelpNotificationService/` | Live Activities and notifications |
| `BighelpTests/`, `BighelpUITests/` | Unit and UI tests |
| `Design/AvatarKit/` | Avatar artwork and the tools that export it |

The look and feel is described in [DESIGN.md](DESIGN.md).

## Contributing

Issues and pull requests are welcome. The maintainer reviews every change
before it merges. See [CONTRIBUTING.md](CONTRIBUTING.md).

Please report security problems privately, as described in [SECURITY.md](SECURITY.md).

## License

[Apache 2.0](LICENSE). Bundled third-party code keeps its own license: BuzzKit
(MIT), ThinkingOrbsKit (MIT), Noto Sans (SIL Open Font License) and WebRTC
(BSD 3-Clause). Provider logos belong to their owners and only identify those
providers.
