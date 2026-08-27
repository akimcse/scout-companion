# Release notes

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
