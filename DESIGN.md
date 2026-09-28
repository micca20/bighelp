# bighelp native iOS presentation

## Authority and scope

The current authority is the **Ember brand kit** (bighelp, a Longview company) and its blended direction:
1a "Messages, evolved" structure, 1b "Center stage" warm cream as light mode, and 1c "After dark" as dark mode.
The app is a simple messaging experience for personal assistant agents. Earlier bighelp/iOS 27 Builder references
are historical (`docs/ui-v3-design.md`).

## Simplicity means hierarchy, not concealment

- Use concise, distinct headers and coherent sections. Group by the person's task, not the code's store or transport boundaries.
- Keep basic options visible and directly editable. Many visible options are appropriate when their grouping makes sense.
- Distinguish advanced options clearly. Do not put every setting behind another menu or create a page per setting.
- Remove repeated headings, instructions that merely restate a control, oversized identity introductions and routine implementation explanations.
- Preserve user-authored names, instructions, content and saved settings. Summarizing a row is not permission to truncate its stored data.
- Keep consequences for credentials, recipients, spending, destructive changes and uncertain saves at the relevant decision. Simplification must not conceal them.
- Aim for understanding setup and ordinary chat in roughly 30 seconds. This is a comprehension target, not a measured authentication-time promise.

## Visual language

- **Ember** (`EmberMark`, `EmberWordmark`, `EmberLockup`) is a perfect coral (#FF8A7A) circle with eyes gazing up. It
  appears only in chrome (root nav bars, icon, splash), never as a chat participant and never in an agent color.
  The wordmark is lowercase SF Pro Rounded heavy and always ends with the coral period: `bighelp.`
- Light: cream canvas #FFF9F5, white cards, #F3ECE6 incoming bubbles, ink #1C1A19. Dark: #121110 canvas,
  #1E1C1B / #292624 surfaces, cream text. Actions are lavender-purple (#7B52E0 light, #C9B6FF dark); outgoing
  bubbles #7B52E0 with white text. All of this lives in `BighelpTheme` so screens read theme tokens, not system colors.
- Settings › Appearance › **Colors** (`AppearanceStudioView`) is the everyday theme editor: a live light/dark preview,
  12 bubble colors (`BighelpBubbleColor`, Lavender is Ember's own), the light page (Cream #FFF9F5 or Paper #FFFFFF)
  and the dark page (Graphite #1C1C1F or Black #000000). High contrast keeps its own pages. Custom themes, import,
  export, fonts and logos sit one tap deeper under More themes; picking one of those clears the bubble color.
- Agents are organic blobs and glossy orbs in their own palette color (`AgentPersonaAvatar`, via `AvatarView`).
  The avatar is the live status indicator: idle, listening, thinking, replying, all set, has an update
  (`AgentLiveState`). States must come from real data.
- Agent Studio's avatar creator (`AvatarCreatorView`) keeps a pet look simple: pick one of the ten kit
  characters (Pinch, Aeria, Biscuit, Miso, Bolt, Rivet, Sage, Inky, Kit, Ember) or ten Bits (Bop, Blok, Wedge,
  Hexo, Drip, Tic, Puff, Boo, Bloom, Glim), then a colorway or main color, headwear (a Bit instead picks its eyes,
  mouth, top and cheeks), a tone-on-tone pattern, and an idle move. The characters come from `Design/AvatarKit`
  (edit `tools/build.py`, then run `tools/build.py` and `tools/export_native.py`); the app draws them natively
  from `Bighelp/Resources/AvatarKit.json`, acting out the agent's state (listening, thinking, waiting on you,
  talking, happy, sleeping) plus extra moves for its current work. The look is saved as the agent's avatar picture and as its
  chat companion.
- Product type is SF Pro. Root screens use large titles; section captions are small, bold, letterspaced and muted.

## Navigation and simplicity

iPhone is an agent home. The bottom bar is **Chat, Feed, Ideas, Goals, Apps**, all for the selected agent.
Chat opens that agent's latest chat with its live avatar big at the top: tap the avatar for its profile (Activity,
Approvals, Schedules, Identity), tap the name to switch agents or open a group chat, and ☰ for new chats, Agents,
Scheduled tasks, Settings and recent chats. The header's compose button starts a chat: one agent picked is a 1:1
chat, two or more a group. The avatar reacts to what the agent is doing (thinking, writing code, browsing, making
images…), driven by the running tool (`AgentActivityKind`, shared with the island as `BighelpActivityPose`). On
phones with a Dynamic Island, the island names the work. In the app it grows into a stage
(`AgentActivityIsland` + `IslandStage`): the name and the work beside the camera, and underneath, the pet acting
it out (chasing a brain while thinking, code streaming from its laptop, fixing a computer, painting, paper
planes…). The status bar hides while it shows, and the app moves down (root `additionalSafeAreaInsets`) so nothing
is covered. Tap for a compact pill, touch and hold to open the chat. Settings › Chat › Agent in the Dynamic Island
turns it off. Outside the app the Live Activity shows the agent's picture and the same icon (the plugin sends only
a fixed category). Every phone chat uses this big-avatar header; only the Chat tab's first page has ☰ and the tab
bar, any other chat (from the list, Feed, a task) has Back. Chat Info lives in ⋯ › People & Chat, and the line under
the name says "Updating…" while a chat reloads from Hermes. iPad works the same way, with no always-open sidebar:
☰ slides the menu in from the leading edge, and chats use the width of the screen. On Vision Pro bighelp always
starts in its own window; the agent can also stand in the room in its own volume (Settings › In your space), and
☰ › Simple mode leaves just the agent, with Open bighelp under it to come back. The avatar never opens by itself.

Widgets (`BighelpActivityShared`, rendered by the Live Activity extension) use the Colors picks through
`BighelpWidgetSnapshot` palettes and show real agent pictures (`BighelpActivityAvatarStore`). **Your Agent** is the
lead widget: the agent's face ringed while it works with a badge for the work, its latest Feed posts and Goals,
New chat, and Chat/Feed/Ideas/Goals links (`loopdy://agent/<tab>`); it also comes in Lock Screen sizes. Active
Chats, Scheduled Tasks, New Chat and Recent Chats share the same look. Tinted and Lock Screen modes fall back to
system styles.

Apps: **Artifacts** lists what the agent made or changed lately, newest first, from one plugin request
(`files.recent`, plugin 2.15+): its `write_file`/`patch` history and deliveries plus new top-level files. It never
walks the whole workspace (a real one holds over a million files); older plugins get a shallow, bounded scan that
skips tooling folders and shows files as it goes. **Media** shows the pictures and videos the agent sent or
generated (`attachments.recent`), then pictures from its posts; tap one for the native preview.

The app icon badge means "something arrived while you were away": pushes set it, opening bighelp clears it
(`BighelpAppBadge`). The app never sets a count of its own, so it can't get stuck on items the user can't see.

Shortcuts run with bighelp closed, in the background or open. The app closes its host connection in the
background, so a Shortcut first proves the host answers (the agent list) and reconnects once if not.

Reactions use Hermes' own: the app saves them with `message.react`, and with Settings › Chat › "Agents see your
reactions" on (the host's `display.message_reactions`), Hermes tells the agent at its next turn. The app sends no
note or turn of its own. Agents tapback through the plugin's `loopdy_react_to_message`. A reply that is only a
silence marker follows Hermes' rules (`ChatSilentReply`).

Feed, Ideas and Goals start empty. They fill only when the user asks the agent for updates; the agent then posts
with the plugin's `bighelp_board` tool, often from a scheduled job it sets up. Nothing runs on the user's AI
provider by itself. Group chats (Hermes hosted rooms / Bot Mode) live in the switcher, ☰ and Agents. Settings shows basics first
(you, assistants/default model/providers, appearance, chat & voice, notifications, Hermes connection). Host
administration — files, gateways/messaging, plugins, MCP, memory, logs, activity, direct links, display & data —
is hidden until **Nerd Mode** is turned on in Settings, which reveals an Advanced section and the More drawer.

Nerd Mode (`settings.nerdModeEnabled`, also the `nerdModeEnabled` environment value) also gates technical detail
inside everyday screens: the chat ⋯ Advanced submenu, the chat Info sheet's visibility toggles and host details,
Project Changes, the token-context ring and subagent rail, Skills/Workspace/Session rows in the + sheet, Agent
Studio's Advanced page and templates, the task editor/detail Advanced groups, and the Chat details defaults in
Settings. Everyday controls must never live only behind it.

## Protected behavior

The [Chat interaction contract](docs/CHAT_INTERACTION_CONTRACT.md) remains authoritative. Preserve the native recycling canvas, canonical ordering, retained draft and editor ownership, reader-controlled scrolling, live/history reconciliation, prepared model, grouped activity and explicit media/voice controls. Do not replace backend clients, authentication, notification delivery, profile ownership or saved data as a styling shortcut.

Existing host capability gates, uncertain outcomes, review/confirmation boundaries and optional permissions remain intact. Unsupported and inherited values must not masquerade as editable effective settings.

## Qualification and release

Record a disposition for each source surface, but never call declaration counts shipping-screen counts. Verify the running result and real controls, including both basic and advanced paths. Label fixture-only, host-backed and hardware-only evidence separately.
