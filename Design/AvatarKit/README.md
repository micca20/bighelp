# bighelp Avatar Kit

Twenty animated, themeable SVG avatars for agents, in two families. Each one breathes, blinks, reacts to taps, follows the pointer with its eyes, and has seven states that map to an agent's lifecycle.

**Characters** have hand-drawn personalities. **Bits** are simple geometric bots with swappable eyes, mouths, accessories and cheeks.

### Characters

| id | Name | Character |
|---|---|---|
| `lobster` | Pinch | Lobster |
| `messenger` | Aeria | Winged messenger |
| `dog` | Biscuit | Dog |
| `cat` | Miso | Cat |
| `zeus` | Bolt | Sky king |
| `robot` | Rivet | Robot |
| `owl` | Sage | Owl |
| `octopus` | Inky | Octopus |
| `fox` | Kit | Fox |
| `dragon` | Ember | Baby dragon |

### Bits

| id | Name | Shape | Default face (eyes / mouth / accessory) |
|---|---|---|---|
| `orb` | Bop | Sphere | round / smile / antenna |
| `cube` | Blok | Rounded cube | visor / flat / headset |
| `wedge` | Wedge | Triangle | dot / cat / sprout |
| `hex` | Hexo | Hexagon | square / smile / crown |
| `drop` | Drip | Teardrop | pill / smile / none |
| `capsule` | Tic | Two-tone capsule | lidded / flat / antenna |
| `cloud` | Puff | Cloud | dot / smile / halo |
| `ghost` | Boo | Ghost | pill / fang / bow |
| `bloom` | Bloom | Flower | round / smile / none |
| `gem` | Glim | Diamond | cyclops / none / halo |

## What's in the folder

- `svg/` standalone animated SVGs (default colors, idle state). Drop into an `<img>` for a static-color animated avatar.
- `avatars.js` ES module with the markup, 9 colorway presets and `mountAvatar()` for web or React Native WebView.
- `ios/AgentAvatarView.swift` SwiftUI view (WKWebView-backed). Add the files in `svg/` to your app target.
- `themes.json` presets and character defaults, for design tokens or a settings screen.
- `preview.html` local playground. Open it in a browser.
- `tools/build.py` the single source. Edit characters or themes here, then run `python3 tools/build.py`.

## States

| State | When to use it | What it does |
|---|---|---|
| `idle` | Waiting | Breathes, blinks, character motion (tail wag, claw pinch, wing flap) |
| `listening` | User typing or mic open | Leans in, pulse ring |
| `thinking` | Reasoning, tool calls | Eyes look up, thought bubble |
| `waiting` | Blocked on the user (approval, a question) | Glances side to side, alert badge |
| `talking` | Streaming a reply | Mouth moves, body chatters (robot shows an equalizer) |
| `happy` | Task finished | Hops, closed-eye smile, sparkles |
| `sleeping` | Offline or paused | Eyes closed, floating Z's |

Set it with the `data-state` attribute on the `<svg>`, `avatar.setState()` on web, or `state:` in SwiftUI.

## Bits faces

Every option works on every Bit. Unset options fall back to that Bit's default.

| Option | Attribute | Values |
|---|---|---|
| Eyes | `data-eyes` | `round` `dot` `pill` `square` `lidded` `visor` `cyclops` |
| Mouth | `data-mouth` | `smile` `cat` `flat` `fang` `none` |
| Accessory | `data-acc` | `none` `antenna` `sprout` `halo` `crown` `bow` `headset` |
| Cheeks | `data-cheeks` | `on` `off` |

Accessories take the accent color. The visor and headset use ink.

## Colorways

Colors are CSS custom properties on the `<svg>`. Anything you leave unset falls back to the character's own palette.

| Variable | Drives |
|---|---|
| `--av-primary` | Main body, cap, shell, coat, Bit shape |
| `--av-secondary` | Bellies, muzzles, hair, ears, toga, Bit panels |
| `--av-accent` | Collars, bolt, iris, sparkles, details |
| `--av-bg` | Backdrop disc |
| `--av-ink` | Pupils, mouths, noses, robot screen |
| `--av-skin` | Skin tone (Aeria, Bolt) |

Presets: `original`, `midnight`, `neon`, `sunset`, `forest`, `ocean`, `royal`, `bubblegum`, `mono`. Per-agent overrides layer on top of a preset.

## Web

```js
import { mountAvatar } from './avatars.js';

const avatar = mountAvatar(document.querySelector('#agent'), {
  character: 'lobster',
  theme: 'neon',                 // preset key
  colors: { accent: '#00E5FF' }, // optional overrides
  state: 'idle',
  onPoke: (id) => console.log('poked', id),
});

avatar.setState('thinking');
avatar.setTheme('ocean');
avatar.setBackground(false);     // hide the disc

// Bits
const bit = mountAvatar(el2, { character: 'cube', face: { eyes: 'cyclops', accessory: 'halo' } });
bit.setFace({ mouth: 'fang', cheeks: false });
bit.setFace({ eyes: null });     // back to the default eyes
```

Inline SVG also works without the module: `<svg ... style="--av-primary:#FF3EA5" data-state="talking">`.

## SwiftUI

```swift
AgentAvatarView(.lobster, colors: .neon, state: agent.isStreaming ? .talking : .idle) {
    Haptics.tap()
}
.frame(width: 96, height: 96)

// Per-agent override on top of a preset
AgentAvatarView(.fox, colors: AgentAvatarColors.ocean.merged(with: .init(accent: "#FFD166")))

// Bits with a custom face. "none" is .hidden for mouths and .bare for accessories.
AgentAvatarView(.cube, colors: .neon,
                face: .init(eyes: .cyclops, mouth: .fang, accessory: .halo, cheeks: false),
                state: .waiting)
```

Each view is a small transparent WKWebView. For long lists, keep live avatars to the visible or active agents, or add `.allowsHitTesting(false)` so the list scrolls freely over them.

## Notes

- Everything is scoped under `.bh-avatar`, with no element ids, so any number of avatars can sit inline on one page with different themes.
- `prefers-reduced-motion` stops all animation.
- Designed on a 200×200 grid; clip to a circle of radius 96 safely.
- Aeria is an original winged-messenger character drawn for this kit.
- Bits are original designs; they share a general idea with other bot avatar systems (simple shapes, expressive eyes) but no artwork.

## bighelp app

The iOS app does not use the WKWebView wrapper in `ios/`. It draws the same art natively from
`Loopdy/Resources/AvatarKit.json`, so avatars also work in saved profile pictures, widgets and
large grids. After changing `tools/build.py`, regenerate both outputs from the repository root:

```sh
python3 Design/AvatarKit/tools/build.py
python3 Design/AvatarKit/tools/export_native.py
```

The exporter supports the SVG and CSS features the kit uses today (paths with M/L/H/V/C/Q/A/Z,
circles, ellipses, rects, text, SVG transforms, the `translate` property driven by `--look`/`--lx`/`--ly`,
keyframed rotate, translate, scale and opacity, and the Bits face options) and stops with an error on
anything else. Each Bits face part records which `data-eyes`/`data-mouth`/`data-acc`/`data-cheeks`
values show it, so the app can swap faces without re-exporting.

