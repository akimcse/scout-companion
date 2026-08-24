# Scout Companion

A lightweight desktop overlay for the **Microsoft Scout** / **OpenClaw** AI agent.

When the agent is working and you've looked away — minimized its window or switched
to another app — Scout Companion pops up a small toast in the corner of your screen
that shows **what the agent is doing right now**. If the agent asks for a permission
("Allow this command?"), you can **Allow or Deny it with one click**, without switching
back to the agent window.

> **Unofficial community project.** Not affiliated with, endorsed by, or supported by
> Microsoft. Use at your own risk. MIT licensed.

### Status at a glance

The whole toast changes color so you can read the agent's state from across the room —
no need to look at the text:

| State | Color | What it means | Preview |
|-------|-------|---------------|---------|
| **Working** | 🟢 Calm dark **green** with a soft glow | The agent is actively running a task | <img src="docs/state-working.png" width="260"> |
| **Idle** | ⚫ Dim **navy** (default) | The agent is connected but waiting / between turns | <img src="docs/state-idle.png" width="260"> |
| **Approval needed** | 🟡 Bright pulsing **yellow** | The agent is asking for permission — Allow / Deny right here | <img src="docs/state-approval.png" width="260"> |
| **Waiting on you** | 🔵 Bright pulsing **cyan** | The agent asked you a question and the turn is parked until you answer | <img src="docs/state-question.png" width="260"> |

The tones are intentionally muted so green and idle sit harmoniously next to each other,
while the two "you are blocking me" colours stay loud enough that you can't miss them.

Approval and question are deliberately different colours. An approval you can settle from
the toast itself; a question you cannot — you have to go to the agent window and answer
it. Telling them apart from across the room decides whether you need to get up.

---

## Why

The desktop agent only shows its live progress and approval prompts inside its own
window. If you minimize it or focus another app while it runs a long task, you have to
keep switching back to check progress or to approve the next step. Scout Companion
mirrors that information into an always-on-top toast and lets you act on approvals in
place.

## Features

- **Live progress toast** — streams the agent's current activity as readable steps
  (e.g. "Reading config.json", "Running: git commit ...") with a ✓/▸ status list, plus
  the agent's latest narration.
- **A mascot to keep you company** — pick from twelve, including five cats and one
  that is not an animal at all. It types while
  the agent is busy, tilts its head and opens its eyes wide when it needs something from
  you, breathes gently when idle, and blinks throughout, so you can tell at a glance
  whether work is happening (see [Mascots](#mascots)).
- **Tray icon** — the companion has no taskbar button and hides its toast most of the
  time, so the tray icon is how you know it is running. Colour carries the state and the
  silhouette carries your chosen mascot, so a glance answers both "is it running?" and
  "is Scout busy?". Right-clicking gives Show/Hide toast, Open Scout, Pause animation,
  Settings and Exit.
- **Settings window** — reachable from the tray or the ⚙ on the toast. Turn on
  start-with-Scout, switch the mascot, dim the toast, turn the animation off, and see
  exactly how much memory and CPU the companion is using (see [Settings](#settings)).
- **Fifteen languages** — follows your Windows display language, or pin one in
  `config.json` (see [Languages](#languages)).
- **Color-coded status** — the whole toast shifts color with the agent's state: calm
  **green** while working, dim **navy** when idle, and bright pulsing **yellow** when an
  approval is needed (see [Status at a glance](#status-at-a-glance)).
- **One-click approvals** — surfaces pending permission requests and clicks the real
  Allow/Deny button inside the agent window for you (via UI Automation — no need to
  bring the window to the foreground). When approval is needed the whole toast turns a
  **bright pulsing yellow** so you can't miss it.
- **Tells you when the agent is stuck on a question** — if the agent asks you something,
  the turn is parked until you answer, exactly like an approval. The toast turns **cyan**,
  shows the question and its options, and offers to bring the agent window forward. It
  cannot answer for you, so it does not pretend to.
- **Follows every session you have open** — if a second agent window asks for approval or
  asks you a question, it reaches the toast too, tagged with which one it came from. The
  step list and narration follow whichever session moved most recently, so with a single
  session it looks exactly as it always did.
- **Open lands on the right conversation** — Open, Answer and the tray don't just raise
  the window, they steer Scout's sidebar to the chat that raised the prompt. If it can't
  work out which chat that is, it brings the window forward and leaves your sidebar
  alone (see [How it works](#how-it-works)).
- **Smart visibility** — stays hidden while the agent window is focused; appears only
  when the agent is busy *and* you've looked away, or whenever an approval is pending.
- **Stays out of the way** — around 1.4% of one CPU core and a flat working set while
  running. The mascot timer stops whenever the toast is off screen, and the session and
  window lookups are cached rather than rescanned every tick.
- **Zero personal data, zero config** — discovers the agent home folder, the active
  session, and the agent window automatically at runtime. Nothing is hardcoded.
- **Lives and dies with Scout** — an optional watcher launches the companion when Scout
  starts and the companion closes itself when Scout quits, so it's only ever running when
  you need it (see [Start and stop with Scout](#start-and-stop-with-scout-recommended)).
- **Single file, no install** — pure PowerShell + WPF. No dependencies, no build step.
  Even the tray icon and every mascot are drawn at runtime; there are no binary assets.

## Mascots

Twelve to choose from, switchable from the settings window without restarting:

<img src="docs/mascots.png" width="720">

Each is a species (the drawing) plus a palette (the colours), which is why the five cats
cost so little to keep around — they share one drawing and differ only in fur, markings
and eye colour. Adding a new colourway is a few lines; adding a new animal is one
function.

**Ribbon** is the exception: no face, no laptop, no paws. It is a band of light that
turns about its own vertical axis and drifts through the colour wheel, taking about
eight seconds to come round. When something is waiting on you the drift stops wandering
and settles into a narrow shimmer around that state's colour, so it reinforces the toast
rather than competing with it. Mascots carry an optional `Desk` flag for this — off means
"does not sit at a laptop", and the laptop and paws are hidden.

The tray icon follows your choice too, reduced to whatever survives at 16 px — ear shape
for the mammals, fins for the tuna, beak for the penguin, a diagonal sash for the
ribbon — while still carrying the state colour.


## Languages

Fifteen, matching the set VS Code ships language packs for: English, 简体中文, 繁體中文,
Français, Deutsch, Italiano, Español, 日本語, 한국어, Русский, Português (Brasil), Türkçe,
Polski, Čeština, Magyar.

It follows your Windows display language by default, walking the culture's parent chain
so `zh-CN` finds `zh-Hans` and `pt-PT` finds `pt`. If nothing matches it stays English.

Set `"language"` in `config.json` to pin one — worth doing if your display language and
your regional format differ, since detection follows the display language:

```json
{ "language": "ko" }
```

English lives in the script itself, so a missing or malformed `lang/*.json` degrades to
English rather than breaking the app, and any key a translation omits falls back on its
own. That means a partial translation is useful immediately.

**Improving a translation** is one file: edit the values in `lang/<tag>.json` and leave
the keys alone. The keys are the English source text. `{0}` is filled in at runtime with
a file name or search term — put it wherever your language wants it, which is often not
where English puts it.


## Requirements

- Windows 10/11
- PowerShell 5+ (ships with Windows) — the launcher runs it in `-STA` mode for WPF
- Microsoft Scout or OpenClaw desktop app installed and running

## Install & run

1. Download/clone this repo anywhere.
2. Double-click **`Start-ScoutCompanion.cmd`**.

That's it. The toast stays hidden until the agent is working in the background.

### Start and stop with Scout (recommended)

Instead of running it for your whole Windows session, you can tie the companion to
Scout's lifetime — it **opens when Scout starts and closes when Scout quits**.

The easy way: open **Settings** from the tray icon and tick **Start automatically with
Scout**. That writes the shortcut below into your Startup folder for you, and unticking
it removes the shortcut again.

To do it by hand instead:

1. Open your Startup folder: `Win`+`R` → `shell:startup`.
2. Create a shortcut whose target is:

   ```
   powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "<path>\Watch-Scout.ps1"
   ```

`Watch-Scout.ps1` is a tiny background watcher: while Scout is closed it does nothing but
a cheap process check every few seconds; when Scout appears it launches the companion,
and the companion shuts **itself** down a few seconds after Scout exits (controlled by
`exitWhenAgentGone` / `exitGraceSeconds` in `config.json`).

If you'd rather have it simply run from login onward, put a shortcut to
`Start-ScoutCompanion.cmd` in the Startup folder instead and set `exitWhenAgentGone` to
`false`.

To stop it: right-click the tray icon and choose **Exit**. Clicking the **✕** on the
toast only hides it until the next approval.

The tray menu's first item is a toggle: **Show toast** pins the toast on screen even when
nothing is happening, and **Hide toast** puts it away again. The caption always names what
the click will do, so it doubles as a readout of whether the toast is currently up.

## Settings

Right-click the tray icon and choose **Settings**, or click the ⚙ on the toast.

| Setting | What it does |
|---------|--------------|
| **Start automatically with Scout** | Adds or removes the `Watch-Scout.ps1` shortcut in your Startup folder. Per-user, no registry writes, no admin rights. The checkbox reads the real state of the folder, so editing it outside the app still shows up correctly. |
| **Animate the mascot** | Off leaves the mascot in a resting pose and stops its timer entirely. Shares one setting with **Pause animation** in the tray menu. |
| **Mascot** | Switches between the twelve mascots live, no restart needed. |
| **Opacity** | Fades the whole toast, from solid down to 35%. Useful if you want it present but not loud. Applies as you drag; the value is saved once you settle. The 35% floor is deliberate — a fully transparent window would still swallow clicks. |
| **This process** | Live working set, CPU and uptime for the companion itself, so "how much is this costing me?" does not require hunting through Task Manager for the right `powershell.exe`. |

Changes are written straight into `config.json`, so they survive a restart. Anything you
put in that file by hand is preserved.

## How it works

The agent writes a per-session event stream to:

```
%USERPROFILE%\.copilot\session-state\<session-id>\events.jsonl
```

Scout Companion:

1. Finds the **active sessions** — the ones whose `events.jsonl` has been written to
   recently. Not the ones holding a lock file: one backend process holds
   `inuse.<pid>.lock` on every session it still has open, so a lock means "some process
   still has this open", not "someone is using this".
2. **Tails each of them** and interprets events:
   - `tool.execution_start` / `assistant.message` → current activity text
   - `permission.requested` / `permission.completed` → pending approvals
   - `external_tool.requested` for an ask-the-user tool → pending question
3. Detects the **agent window** from the running process list and checks whether it's
   minimized or in the foreground to decide when to show the toast.
4. For approvals, it wakes each agent window's accessibility tree and invokes the
   matching **Allow/Deny** button through Windows UI Automation. Which window raised the
   approval cannot be read from the session state — the lock names a backend process, not
   a UI one — but it can be seen: the window showing the prompt is the one with the button
   on screen. It clicks only when exactly one window qualifies, and focuses instead when
   none or several do, because approving something nobody read is worse than making you
   click it yourself.
5. For **Open**, it also tries to put Scout on the chat the prompt came from.

### Finding the chat a prompt came from

Scout's chats and the folders the companion follows are two different id namespaces: a
chat in the sidebar is keyed by an id that never appears in `session-state`, and the
index that would join them is encrypted on disk. There is no lookup to do — a session
cannot be named from the outside.

What the sidebar *does* hand over, once its chat search field is open, is every chat's
title and how long ago it was last touched. So the companion finds the chat the way you
would:

1. Open the sidebar and its search field if they're collapsed.
2. Type something the session has talked about — the first thing you asked it for, or the
   project folder if the session opens with a bare "carry on".
3. Read the rows that come back, each carrying a **title** and a **when** (`Just now`,
   `4m ago`, `8/15/2026`).
4. Take the freshest row whose *when* could plausibly be this session. Plausibly, not
   exactly: Scout's timestamps **lag** for a chat that isn't the one on screen — a chat
   being written to right now can still read `11m ago` — but they only ever lag, never
   run ahead. So the window is lopsided: a little slack below to absorb rounding, a lot
   above to absorb the lag, and the freshest row inside it wins. Where two rows tie, the
   search's own ordering breaks it.
5. Clear the search and re-collapse anything that was opened, so the sidebar ends up
   exactly as it was found.

The caret is never taken. The search field accepts a value without being focused, and
focusing it would pull the cursor out of whatever you were typing at the time — the
companion works in the background, so it has no business moving your cursor.

The session's own clock is read from its last **message**, not its last event — a session
ten minutes into a run of tool calls hasn't "just" done anything as far as Scout's chat
list is concerned, and comparing the two clocks directly never matches.

The search is semantic, so it is only trusted to bring the chat *into view* — the
timestamp is what decides. **If nothing plausible comes back, nothing is clicked**: the
window has already been brought forward, and sending you to the wrong conversation is
worse than leaving you where you were. The same is true if the sidebar isn't there at
all — Scout drops it entirely below a certain window width. Set `openMatchingSession` to
`false` to skip this whole step.

`Test-SessionMatch.ps1` covers the picker against row lists captured from a real sidebar,
including the lagging-timestamp case:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File Test-SessionMatch.ps1
```

`Test-ButtonSearch.ps1` covers the other half — the search that decides where **Allow**
and **Deny** get clicked — against real windows, since Scout will not raise an approval
on demand. It opens a few throwaway windows while it runs, so it needs a desktop and an
STA host:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -STA -File Test-ButtonSearch.ps1
```

Approvals and questions are merged across every followed session; the step list and
narration come from whichever moved most recently. A session with something pending is
kept even after it goes quiet, because an approval does not expire just because nobody
has typed for a while.

### Naming the conversation on the toast

A prompt carries a second line under its heading saying which conversation raised it,
and in the ordinary working state the header carries the same line for whichever
conversation the step list and narration belong to. The toast spends nearly all of its
life in that ordinary state, so naming only the prompts would have left the label
practically invisible.

The name is Scout's own chat title once the search above has found it, and until then
the latest thing that session was asked to do — the *latest*, not the first, because a
resumed session opens with "carry on" and naming it that would be worse than useless.
A bare project folder is only shown when more than one session is being followed; on
its own it says almost nothing, and it reads the same for every session on the project.

While a prompt is up the header drops its own name and only the card is labelled: the
conversation asking for permission need not be the one whose steps were scrolling past
a moment earlier, and two different names on one toast would be worse than one.

One card shows one prompt, and the header counts everything else that is queued —
`Approval needed (+2)` — across both kinds. Counting only the shown prompt's own kind
was worse than not counting at all: an approval standing in front of two questions read
as a lone approval, and the questions left no trace on screen to say they were waiting.

The session set and the agent window are both cached — the poll tick normally costs one
file stat per followed session and one `IsWindow` call, rather than a walk over every
session folder and every process on the machine.

No network calls. No data leaves your machine. The companion only reads local files and
interacts with the local agent window.

## Configuration (optional)

Everything works out of the box, and the settings window covers the things worth changing
day to day. To go further, copy `config.sample.json` to `config.json` (next to the script)
and edit. Common overrides:

| Field | Default | Purpose |
|-------|---------|---------|
| `home` | auto-detected | Agent home folder |
| `processNames` | `["Microsoft Scout","OpenClaw",...]` | Agent window process names |
| `allowLabels` / `denyLabels` | `["Allow",...]` / `["Deny",...]` | Buttons to click for approvals |
| `askToolNames` | `["m_ask_user","ask_user"]` | Tool names that mean "waiting for your answer" |
| `activeWindowSeconds` | `150` | How long after the last event the session counts as "working" |
| `pollIntervalMs` | `700` | Event/focus polling interval |
| `maxSessions` | `6` | How many concurrently active sessions to follow |
| `sessionRescanMs` | `5000` | How often to re-resolve which session is active. Between rescans the companion just tails the file it already found |
| `animIntervalMs` | `80` | Mascot frame interval (80 = 12.5 fps). The mascot moves at the same speed whatever you set |
| `animationEnabled` | `true` | Whether the mascot animates. Also in the settings window |
| `mascot` | `quokka` | Which mascot to show. Also in the settings window |
| `language` | `auto` | UI language. `auto` follows the Windows display language; set a tag from `lang/` to pin it |
| `opacity` | `1.0` | Toast opacity, clamped to 0.35–1.0 on load. Also in the settings window |
| `startupGreetingSeconds` | `5` | Show the toast briefly at startup so launching the companion has a visible result. `0` starts silently |
| `exitWhenAgentGone` | `true` | Close the companion shortly after the agent app quits |
| `exitGraceSeconds` | `30` | How long the agent must stay gone before the companion exits |

You can also point it at a different home folder with the `SCOUT_COMPANION_HOME`
environment variable.

`config.json` is git-ignored so your local tweaks never get committed. The settings window
writes to this same file, merging rather than overwriting, so hand-written keys survive.

## Troubleshooting

- **Is it even running?** — look for the mascot in the notification area. Windows 11 puts
  new tray icons behind the **^** chevron by default; drag it onto the taskbar to keep it
  visible.
- **Toast never appears** — make sure the agent is actually running a task. The toast is
  intentionally hidden while the agent window is focused. Minimize it and start a task.
- **"Agent not detected"** — your build may use a different process name; add it to
  `processNames` in `config.json`.
- **I launched it and nothing happened** — it says hello for five seconds now, so you
  should see the toast once. After that it follows the normal rules, and the main one is
  that it stays out of the way while Scout has focus — so if you launch it and then keep
  typing in Scout, you will not see it again until Scout is in the background or something
  needs you. Its tray icon also starts life in Windows' hidden overflow flyout (the `^`
  next to the clock); drag it onto the taskbar to keep it in sight. From that icon,
  **Show toast** pins the toast on screen permanently.
- **Allow/Deny clicks the wrong thing or does nothing** — the button captions in your
  build may differ; adjust `allowLabels` / `denyLabels`. Scout currently shows **Allow**,
  **Allow for session**, **Allow everywhere**, and **Deny**; the toast's **Allow** maps to
  the safest one-time **Allow**. As a fallback the companion focuses the agent window so
  you can click manually.
- **Allow/Deny stopped clicking when I opened a second agent window** — fixed. It used to
  count windows and give up above one, which turned the buttons into nothing at all as
  soon as you worked in two Scout windows. It now looks for the prompt itself and clicks
  in the window that is showing it. It still declines if two windows are showing a prompt
  at once, since the approval could belong to either; answer one in Scout and the toast
  can take the other.
- **Start-with-Scout won't turn on** — the checkbox disables itself if `Watch-Scout.ps1`
  is missing from the same folder as the script, and reverts if the Startup folder cannot
  be written.
- **Open raises the window but doesn't switch chat** — it only switches when it is sure.
  No chat whose timestamp could plausibly be that session means no click, and if the
  Scout window is narrow enough that the sidebar is gone there is nothing to search at
  all. Widen the window, or set `openMatchingSession` to `false` if you would rather it
  never tried.
## Privacy & safety

- Reads only local session files and the local agent window. No telemetry, no network.
- Clicking **Allow** here is exactly equivalent to clicking Allow in the agent — it does
  not bypass any of the agent's own permission checks; it just forwards your click.
- Treat approvals with the same care you would in the agent itself.

## License

[MIT](LICENSE)
