# Animation plans

Plans written by the `improve-animations` skill. Each one is self-contained, so any agent can
carry it out without this conversation's context.

| # | Plan | Severity | Status |
| --- | --- | --- | --- |
| 001 | [Make a guide bot fly to the line being edited](001-guide-bot-flies-to-edited-line.md) | HIGH | DONE |
| 002 | [v2 bots: bigger, small eye styles, physics motion](002-v2-bots-physics.md) | MEDIUM | TODO |

## Order

1. **001** (done). The star perches beside the line being edited and looks at the caret.
2. **002** next. It needs 001 and replaces `Sources/Kite/BotsOverlay.swift` with the checked file in
   `002-files/`. It changes only the look and motion, not the guide rules.

## Tried and dropped

- **2.5D bots** (side edge, lighting, turning parallax). Mocked up on the design canvas on 2026-11-06
  and rejected because it looked bad. Don't revive it without a new design.
