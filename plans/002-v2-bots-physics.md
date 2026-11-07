# 002 — v2 bots: bigger, small eye styles, physics motion

- **Status**: TODO
- **Commit**: none (not a git repository yet; written 2026-11-06 against `~/kite` with plan 001 applied)
- **Severity**: MEDIUM
- **Category**: Physicality & origin / Interruptibility / Cohesion
- **Estimated scope**: 1 file replaced (`Sources/Kite/BotsOverlay.swift`, about 680 lines); no other source changes
- **Depends on**: 001 (DONE). This keeps 001's guide behavior and public API.

## Problem

The bots in the app still use the v1 design, while the Kite Bots design canvas ("v2" row) moved on:

- **Size and faces.** The app's bots are 36 pt with large white eyes and pupils
  (`Sources/Kite/BotsOverlay.swift`, `private final class Bot`, `static let size: CGFloat = 36`).
  The v2 design is bigger, with small, varied eye styles.
- **Motion has no physics.** Every move is a fixed Core Animation spring (`walk(to:)`, `fly(to:)` →
  `move(to:with:)`), with a separate keyframe lean and a keyframe pop on morph. There's no anticipation, no
  squash on landing and no stretch along motion. A flight restarted mid-air begins from the on-screen
  position but with **zero velocity**, so redirects look like a sudden stop and go.
- **Wandering looks like drifting.** Wanderers slide in straight lines across the whole view instead
  of moving like small creatures.

## Target

Replace `Sources/Kite/BotsOverlay.swift` with **`plans/002-files/BotsOverlay.swift`**, byte for byte.
That file compiles against the current code with no warnings. It was checked in a throwaway copy of
Kite: an offscreen render, plus a scripted run of the real app with the guide flying, being
redirected and dodging typed text, wanderers hopping, and the display link pausing when idle.

What it does, with the exact values it uses:

| Aspect | Value |
| --- | --- |
| Bot size | `52` pt (was 36). The design's 100-unit drawings scale by `unit = size / 100`. |
| Body | Same 120-point shapes and morph. Radius `38 × unit`, rounded stroke `13 × unit`. |
| Eye styles (small, dark `#1B1D22`) | circle: **beads**, triangle: **happy** (closed arcs, no blink), square: **pixel**, pentagon: **sparkle**, star (the guide): **beans**. Eight styles are defined in `EyeStyle`; the other three (sleepy, peepers, cyclops) are available for later. |
| Guide flight | Physics spring: stiffness `158`, damping `20.1`. That is Apple's perceptual spring for duration `0.5 s`, bounce `0.2`. **Velocity carries through redirects**, so a new target bends the path. |
| Wanderer hop | Crouch `0.14 s` (squash target `+0.2`), then a ballistic arc under gravity `1800 pt/s²` peaking `28–56 pt` above the higher end, landing exactly on target. Hops are `60–220 pt` long, every `3–7 s`. 25% of hops morph the shape at takeoff. |
| Squash and stretch | Jelly spring: stiffness `560`, damping `13`, clamped to `−0.3…0.35`. Stretch along the direction of motion up to `0.16` (speed ÷ 2600). Takeoff impulse `−6`, landing impulse `speed × 0.004`, morph pop `−3`. Feet stay planted while squashing. |
| Lean | Spring stiffness `140`, damping `12` toward `vx × 0.0005` (±0.3 rad). |
| Eyes | Trail the motion (spring stiffness `220`, damping `20`). At rest, the guide's eyes watch the caret. |
| Unchanged Core Animation | Color cycle (8 colors, 3.5 s each), idle bob (±1.5 pt), blink (0.18 s), morph (0.55 s, `cubic-bezier(0.3, 0, 0.2, 1)`). |
| Reduced motion | No hops and no travel. The guide fades in at its perch: opacity 0 → 1, `200 ms`, `cubic-bezier(0.23, 1, 0.32, 1)`. |
| Cost when idle | The simulation is stepped by `NSView.displayLink(target:selector:)` (macOS 14+) in fixed 1/240 s substeps, and **pauses itself whenever every bot is settled**. Hops and flights wake it. |

Guide rules from plan 001 are unchanged: fly after 250 ms on a new line, dodge typing with a 48 pt
lead, no drift within 72 pt, ride along with scrolling. Scrolling now shifts the guide **and its
in-flight target** by the scroll distance, so a flight continues relative to the line instead of being cut short.

## Repo conventions to follow

- The public API used by `EditorWindowController` is unchanged: `BotsOverlay.didToggle`,
  `BotsOverlay.isEnabled`, `FocusReason`, `requestFocus`, `focus(lineRect:caret:reason:)`, `scatter()`.
  **`EditorWindowController.swift` needs no edits.**
- `BotShape` (the 120-point shapes) is copied unchanged from the current file.
- Timers hop to the main actor with `MainActor.assumeIsolated { … }`, as before.

## Steps

1. Copy `plans/002-files/BotsOverlay.swift` over `Sources/Kite/BotsOverlay.swift`:
   `cp plans/002-files/BotsOverlay.swift Sources/Kite/BotsOverlay.swift`
2. Check the copy is exact: `shasum -a 256 Sources/Kite/BotsOverlay.swift` must print
   `3e7cce43bbd5e260cafd4a9ba81b689d2b5383c5ed11c417ad0bbf9b7897c012`.
3. Before step 1, confirm the current `Sources/Kite/BotsOverlay.swift` contains `func focus(lineRect: CGRect, caret: CGPoint, reason: FocusReason)`
   and `func fly(to target: CGPoint)`, which shows plan 001 is applied. If not, STOP and report.

## Boundaries

- Do NOT edit the copied file to "improve" it. Report problems instead.
- Do NOT touch `EditorWindowController.swift`, `EditorView.swift`, `DevTools.swift` or any other file.
- Do NOT add dependencies.
- If `swift build` reports any error or warning in `BotsOverlay.swift`, STOP and report it verbatim.

## Verification

- **Mechanical** (from `~/kite`):
  - `swift build` succeeds with no warnings in `BotsOverlay.swift`.
  - `swift test` passes all 45 tests.
  - `.build/debug/Kite --render examples/demo.swift /tmp/v2.png --size 700x420` shows five 52 pt bots with small
    eyes: two dots on the circle, ^ ^ arcs on the triangle, two small squares on the square,
    shiny dots on the pentagon and tall ovals on the star.
  - `scripts/bundle.sh && open build/Kite.app --args "$PWD/examples/demo.swift"` launches.
- **Feel check** (in the running app):
  - A wanderer about to move first **crouches** briefly (wider and shorter), springs up on an arc,
    **squashes** on landing, then wobbles back to round in well under a second. It should feel like a
    small jelly creature, not a slide.
  - Click line 10: the star flies there, stretched slightly along its path, overshoots a little and settles.
  - Click line 3, then line 20 while it's still flying: it **keeps moving and curves** toward line 20.
    There's no stop-and-restart.
  - Typing at the end of the star's line: it hops ahead about every six characters (plan 001 behavior still holds).
  - Scroll while the star is flying: it keeps flying toward its line as the line moves.
  - Wanderers never land on the edited line's band or on top of each other.
  - Slow motion: in `Bot`, temporarily multiply `dt` by `0.2` at the top of `step(_:)`, rebuild, and watch a hop
    and a flight. The crouch should come before takeoff, the stretch should follow the motion, and
    the landing squash should be anchored at the feet. Remove the change afterwards.
  - Idle cost: in Activity Monitor, Kite's CPU should drop to about 0% between hops. With View ▸ Show
    Bots off, or System Settings ▸ Accessibility ▸ Display ▸ Reduce motion on, it should stay at about 0%.
  - Reduce motion on: no hops. Moving to a new line makes the star fade in at its perch.
- **Done when**: build and tests pass, the hash matches, every feel check holds, and the slow-motion change is removed.
