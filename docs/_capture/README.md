# Screenshot harness

Regenerates the toast screenshots in `docs/` without needing a running Scout.

```powershell
powershell -STA -NoProfile -ExecutionPolicy Bypass -File docs\_capture\capture.ps1
```

`capture.ps1` slices the live `scout-companion.ps1` up to just before the poll
timer starts (so every function, the window and the mascots load, but no real
session is read), injects fake session state for each visual state, and renders
each to a PNG via `RenderTargetBitmap` at 2x. The UI is rendered in Korean.

Outputs: `state-working.png`, `state-approval.png`, `state-question.png`,
`state-idle.png`. The UI is rendered in English with generic sample content.
