# Release notes

## v0.10.0 — Talk to the Scout conversation already on screen

Voice control is now an optional part of Scout Companion. Say “Hey Scout” and the
recognized command is typed into the conversation currently open in Scout; when that turn
finishes, Companion can read the final answer aloud even while Scout is minimized or behind
another app.

### New

- **Current-conversation voice commands.** The existing Scout chat keeps its full context,
  permissions, tools, and visible history instead of sending speech to a separate agent.
- **Independent input and output settings.** Enable voice commands and spoken answers
  separately under **음성으로 제어**. Both choices persist in `config.json`.
- **Five-phrase enrollment.** First-time users can prepare the optional runtime and enroll
  their voice from Settings. Raw recordings are discarded; the encrypted speaker embedding
  stays under the current Windows profile.
- **Wake and noise sensitivity.** Two 0–100 sliders tune fuzzy “Hey Scout” matching and
  ambient-noise rejection.
- **Portable optional runtime.** Release packages include the Python sources and a preparer
  that creates a per-user environment and downloads the on-device speech models only when
  enrollment is requested.

### Changed

- A minimized Scout window always leaves the Companion toast visible, even while idle.
- Consecutive wake phrases are no longer submitted as commands.
- Spoken answers can only be interrupted by an explicit wake phrase, preventing TTS echo
  and background noise from generating accidental Scout turns.
- Answer completion follows Scout's session event stream rather than an on-screen button,
  so spoken output does not depend on window focus.

### Notes

- Voice control is off by default and does not add a separate startup task.
- Python 3.11 or later is required only for voice control. First-time setup downloads about
  200 MB of speech models.

## v0.8.0 — One toast for one session or many

The single-session and multi-session toasts were two different shapes; now they are one.
Every conversation — whether it is the only one running or one of several — sits on its own
**session row**: an accent bar, the conversation's name, and what it is doing right now led
by a small ▸ marker. A single session adds its fuller ✓/▸ step list beneath its row; several
sessions show a row each. The old italic narration line and the header's separate name line
are gone, because the row now carries the name in both cases.

### New

- **Click a session row to open that chat.** Clicking a row (or the toast header) steers
  Scout's sidebar to that conversation, not just raises the window. If it can't be sure
  which chat the row belongs to, it brings the window forward and leaves your sidebar
  alone. The old **Open** button is gone — the header and rows are the click target now.
- **Choose which name the row shows.** New **Show the chat-list name** setting. Off (the
  default) the row shows what you last asked that session to do, so a prompt you just sent
  is not replaced by a summarised title the moment it is learned; on, it shows Scout's own
  sidebar title. Also configurable as `showChatTitle` in `config.json`.
- **Scheduled automations are excluded.** An automation run is headless and can't be
  opened, so it's left off the toast entirely — detected by the runner reminder Scout
  injects into its first turn (a chat that merely *discusses* automations is unaffected).

### Changed

- **Unified single/multi layout.** The toast leads with a session row in both cases, so it
  reads the same whether one job is running or five.
- **Activity lines match the step list.** The running command under a row now carries the
  same ▸ marker the step list uses, so it reads as a step rather than a second title.
- **Tidied settings window.** Two-column stats, hover tooltips (ⓘ) instead of always-on
  hint text, a drawn gear icon, and the version moved under Updates.
- **Mascot sizing.** The mascot's layout box was trimmed so the header no longer has an
  empty band above and below it.

### Notes

- Version is **0.8.0**: a new capability (click-to-open, the name toggle, the unified
  layout), so a minor bump.
- Settings and learned chat titles carry across an in-place update as before.
- Screenshots in `docs/` are regenerated from the new UI by `docs/_capture/capture.ps1`.
