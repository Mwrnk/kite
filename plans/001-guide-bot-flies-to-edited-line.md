# 001 — Make a guide bot fly to the line being edited

- **Status**: DONE (2026-11-06)
- **Commit**: none (not a git repository yet; written 2026-11-06 against the files as they are in `~/kite`)
- **Severity**: HIGH
- **Category**: Purpose & frequency / Missed opportunity
- **Estimated scope**: 2 files, about 120 lines added, a few changed

## Execution notes

Carried out on 2026-11-06, with two fixes found while checking it in the running app:

1. **Perch clamp.** Clamping the perch to the wanderers' walk area (32 pt inset) left the guide below
   line 1. The guide now clamps to its own `perchArea`, `bounds.insetBy(dx: Bot.size / 2 + 2, dy: Bot.size / 2 + 2)`,
   using a small `CGRect.clamp(_:)` helper.
2. **Scrolling.** `.scrolled` used `perch()`, which drops the 48 pt typing lead, so every scroll
   nudged the guide 24–48 pt sideways. It now keeps its current x and only follows the line's y:
   `guide.jump(to: perchArea.clamp(CGPoint(x: guide.node.position.x, y: lineRect.midY)))`.

Checked with a scripted run of the real app: the debounce, a single flight after holding ↓, 8 hops
while typing 60 characters, no drift on pause, and riding along with scroll. Not checked: the
Reduce motion fade, and how it feels on a real screen.

## Problem

Kite's bots exist to teach. A future AI tutor will explain the code you are working on, and the
bots are how it points at that code. Right now every bot wanders to random spots, so nothing on
screen connects them to your work.

The wandering is picked at random in `Sources/Kite/BotsOverlay.swift:77` and fired from the tick at
`Sources/Kite/BotsOverlay.swift:105`:

```swift
// Sources/Kite/BotsOverlay.swift:77 — current
private func randomPoint() -> CGPoint {
    let a = walkArea
    return CGPoint(x: .random(in: a.minX...a.maxX), y: .random(in: a.minY...a.maxY))
}
```

```swift
// Sources/Kite/BotsOverlay.swift:105 — current, inside tick()
if now >= bot.nextMove {
    bot.walk(to: randomPoint())
    bot.nextMove = now + .random(in: 2.5...5.5)
}
if now >= bot.nextMorph {
    bot.morph(to: BotShape.allCases.filter { $0 != bot.shape }.randomElement()!)
    bot.nextMorph = now + .random(in: 7...14)
}
```

The window controller already learns about every caret move and text change
(`Sources/Kite/EditorWindowController.swift:147`, `editorDidChange(textChanged:)`) and every scroll
(the `boundsDidChangeNotification` observer at `Sources/Kite/EditorWindowController.swift:56`), but it
never tells the bots.

## Target

One bot, the **star** (the last of `BotShape.allCases`, called Twinkle in the designs), becomes the
**guide**. It perches just to the right of the end of the line holding the caret, at that line's
vertical middle, and looks at the caret. The other four bots keep wandering but stay out of that line.

How often it moves matters most. Editing is the most frequent thing anyone does in an editor, so
**the guide must not move on every keystroke**:

| What happened | What the guide does |
| --- | --- |
| Caret moved to a **different line** (arrows, click, Return) | Waits until the caret has stayed on that line for **250 ms**, then flies there once. Holding ↓ through 40 lines gives one flight at the end, not 40. |
| Typing on the **same line** brings the text end to within 4 pt of the guide's left edge | Flies right **immediately** (no wait), landing **48 pt** (about six characters) further out than its normal perch, so it hops once every few words instead of on every keystroke. |
| Typing on the same line while the text is still short of the guide | Stays put. |
| Text on the same line got **shorter** | Stays put while the guide is no more than **72 pt** right of its normal perch. Beyond that it waits 250 ms after the last change, then moves left. |
| The view **scrolled** | Moves with the line instantly, with no animation, so it stays glued to the text. |
| The line is scrolled out of view | The perch is clamped to the walk area, so the guide waits at the top or bottom edge. |

The flight:

- A spring that starts from the bot's **current on-screen position** (`presentation()`), so a new
  target mid-flight redirects it instead of restarting. Use Apple's perceptual spring:
  `CASpringAnimation(perceptualDuration: 0.5, bounce: 0.2)` (available on macOS 14 and later; Kite requires 15).
  Settling time is `spring.settlingDuration`.
- Keep the existing lean (the `"lean"` keyframe animation in `walk(to:)`).
- During the flight the pupils look where it is going (existing behavior). **450 ms** after takeoff
  they turn to look at the caret, over 0.3 s.
- Perch point: `x = max(lineTextEnd, caretX) + 10 + Bot.size / 2 (+ 48 when dodging typing)`, `y = line.midY`, clamped to the walk area.

Reduced motion (`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`): no travel. The guide
moves to the perch instantly and fades in: opacity 0 → 1, **200 ms**, `cubic-bezier(0.23, 1, 0.32, 1)`.

The guide never morphs and never wanders while it has a line to perch on.

## Repo conventions to follow

- All bot motion is Core Animation. Positions are set on the model layer inside
  `CATransaction.setDisableActions(true)`, then an explicit animation is added. Imitate `walk(to:)`
  at `Sources/Kite/BotsOverlay.swift:275`.
- The overlay's coordinates are flipped (y grows downward): `override var isFlipped: Bool { true }`.
- Timers and observers hop back to the main actor with `MainActor.assumeIsolated { … }`. See the
  tick timer in `viewDidMoveToWindow()` in `BotsOverlay.swift`.
- `Bot` is `private final class Bot` in the same file, so `BotsOverlay` can call its methods and use `Bot.size`.
- Comments are short, plain sentences explaining why. No AI attribution anywhere.

## Steps

### 1. `Sources/Kite/BotsOverlay.swift`: focus state and the public entry point

Under `private var placed = false` (line 22), add:

```swift
    /// Why the focus changed; decides how the guide reacts.
    enum FocusReason { case scrolled, edited, caretMoved }

    /// Asked for fresh focus coordinates once the view has its real size.
    var requestFocus: (() -> Void)?

    /// The edited line's text, in this view's coordinates. Nil until the editor reports one.
    private var focusLine: CGRect?
    private var caretPoint: CGPoint = .zero
    private var pendingFlight: DispatchWorkItem?
    /// The star perches beside the line being edited.
    private var guide: Bot { bots[bots.count - 1] }
```

### 2. `BotsOverlay.swift`: ask for focus after the first placement

In `override func layout()` (line 44), change the first-placement branch from:

```swift
        if !placed {
            placed = true
            scatter()
        } else {
```

to:

```swift
        if !placed {
            placed = true
            scatter()
            requestFocus?()
        } else {
```

### 3. `BotsOverlay.swift`: keep wanderers off the focused line

Replace `randomPoint()` (line 77) with:

```swift
    private func randomPoint() -> CGPoint {
        let a = walkArea
        var p = CGPoint(x: a.midX, y: a.midY)
        // A few tries to land away from the line the guide is pointing at.
        for _ in 0..<8 {
            p = CGPoint(x: .random(in: a.minX...a.maxX), y: .random(in: a.minY...a.maxY))
            if let line = focusLine, abs(p.y - line.midY) < 40 { continue }
            return p
        }
        return p
    }
```

### 4. `BotsOverlay.swift`: the guide skips wandering and morphing

In `tick()`, change the two blocks quoted in Problem (starting line 105) to:

```swift
            if bot === guide { continue }   // the guide only moves when the edited line does
            if now >= bot.nextMove {
                bot.walk(to: randomPoint())
                bot.nextMove = now + .random(in: 2.5...5.5)
            }
            if now >= bot.nextMorph {
                bot.morph(to: BotShape.allCases.filter { $0 != bot.shape }.randomElement()!)
                bot.nextMorph = now + .random(in: 7...14)
            }
```

The `continue` goes **after** the blink block and **after** `if reduceMotion { continue }`, so the guide still blinks.

### 5. `BotsOverlay.swift`: the focus logic

Add these methods to `BotsOverlay`, after `tick()` and before the closing `}` of the class:

```swift
    // MARK: Guide

    /// Called when the caret moves, the text changes or the view scrolls. `lineRect` spans the
    /// line's text, from its left edge to where the text ends; `caret` is the caret's center.
    /// Both are in this view's coordinates.
    func focus(lineRect: CGRect, caret: CGPoint, reason: FocusReason) {
        let previous = focusLine
        focusLine = lineRect
        caretPoint = caret
        guard placed else { return }

        switch reason {
        case .scrolled:
            // Ride along with the text; a pending flight still reads the fresh perch when it fires.
            guide.jump(to: perch())
        case .edited, .caretMoved:
            let sameLine = previous.map { abs($0.midY - lineRect.midY) < 1 } ?? false
            let current = guide.node.position   // where the last flight is headed
            let textEnd = max(lineRect.maxX, caret.x)
            if sameLine && textEnd + 4 > current.x - Bot.size / 2 {
                // The text is about to run into it: hop well clear, right away.
                pendingFlight?.cancel()
                flyGuide(lead: 48)
            } else if sameLine && (0...72).contains(current.x - perch().x) {
                return                           // close enough; don't fidget while typing
            } else {
                scheduleFlight(after: 0.25)      // wait for the caret to settle
            }
        }
    }

    /// Where the guide sits: just right of the line's text, plus `lead` extra room.
    private func perch(lead: CGFloat = 0) -> CGPoint {
        guard let line = focusLine else { return guide.node.position }
        let x = max(line.maxX, caretPoint.x) + 10 + Bot.size / 2 + lead
        return clamp(CGPoint(x: x, y: line.midY))
    }

    private func scheduleFlight(after delay: TimeInterval) {
        pendingFlight?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flyGuide() }
        }
        pendingFlight = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func flyGuide(lead: CGFloat = 0) {
        pendingFlight?.cancel()
        pendingFlight = nil
        guard focusLine != nil, !isHiddenOrHasHiddenAncestor else { return }
        let target = perch(lead: lead)
        let here = guide.node.position
        if abs(target.x - here.x) < 1 && abs(target.y - here.y) < 1 {
            guide.look(at: caretPoint)           // already there (e.g. pinned at the right edge)
            return
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            guide.appear(at: target)
            guide.look(at: caretPoint)
        } else {
            guide.fly(to: target)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.guide.look(at: self.caretPoint)
                }
            }
        }
    }
```

### 6. `BotsOverlay.swift`: new `Bot` movements

In `private final class Bot` (line 189), replace the whole `func walk(to target: CGPoint)` (line 275,
through its closing brace just before `func morph`) with the version below. `walk` keeps its slow,
floaty spring for wandering; `fly` is the quicker spring used for purposeful moves; both share `move`.

```swift
    /// Slow, floaty wandering.
    func walk(to target: CGPoint) {
        let spring = CASpringAnimation(keyPath: "position")
        spring.mass = 1
        spring.stiffness = 40
        spring.damping = 11
        move(to: target, with: spring)
    }

    /// A purposeful move to the code being edited. Starts from where the bot is on screen right
    /// now, so a new target mid-flight redirects it instead of restarting.
    func fly(to target: CGPoint) {
        let spring = CASpringAnimation(perceptualDuration: 0.5, bounce: 0.2)
        spring.keyPath = "position"
        move(to: target, with: spring)
    }

    private func move(to target: CGPoint, with spring: CASpringAnimation) {
        let from = node.presentation()?.position ?? node.position
        spring.fromValue = NSValue(point: from)
        spring.toValue = NSValue(point: target)
        spring.duration = spring.settlingDuration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        node.position = target
        CATransaction.commit()
        node.add(spring, forKey: "walk")

        // Lean into the move, then straighten up.
        let dx = target.x - from.x, dy = target.y - from.y
        let lean = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        lean.values = [0, (dx > 0 ? 1 : -1) * min(abs(dx) / 600, 0.2), 0]
        lean.keyTimes = [0, 0.3, 1]
        lean.duration = 1.2
        lean.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        node.add(lean, forKey: "lean")

        // Look where it's going.
        look(direction: CGPoint(x: dx, y: dy))
    }

    /// Moves instantly, cancelling any flight. Used while scrolling.
    func jump(to target: CGPoint) {
        node.removeAnimation(forKey: "walk")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        node.position = target
        CATransaction.commit()
    }

    /// Reduced motion: no travel, just fade in at the new spot.
    func appear(at target: CGPoint) {
        jump(to: target)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.2
        fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
        node.add(fade, forKey: "appear")
    }

    /// Turns the pupils toward a point in the overlay's coordinates.
    func look(at point: CGPoint) {
        look(direction: CGPoint(x: point.x - node.position.x, y: point.y - node.position.y))
    }

    private func look(direction d: CGPoint) {
        let length = max(hypot(d.x, d.y), 1)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        for pupil in pupils {
            pupil.position = CGPoint(x: 4 + 1.6 * d.x / length, y: 4.5 + 1.8 * d.y / length)
        }
        CATransaction.commit()
    }
```

### 7. `Sources/Kite/EditorWindowController.swift`: report the edited line

Add this method to `EditorWindowController`, right after `private func editorDidChange(textChanged:)` (line 147):

```swift
    /// Tells the bots where the line being edited is, in the bots view's coordinates.
    private func updateBotFocus(_ reason: BotsOverlay.FocusReason) {
        guard !bots.isHidden else { return }
        let editor = editorView.editor
        let buffer = editor.buffer
        let line = buffer.line(containing: editor.caret)
        let caret = editorView.caretRect(for: editor.caret)
        let textEnd = editorView.x(ofOffset: buffer.lineRange(line).upperBound)
        let lineRect = NSRect(x: editorView.textInsetX, y: editorView.lineTop(line),
                              width: max(textEnd - editorView.textInsetX, 0), height: editorView.lineHeight)
        bots.focus(lineRect: bots.convert(lineRect, from: editorView),
                   caret: bots.convert(NSPoint(x: caret.midX, y: caret.midY), from: editorView),
                   reason: reason)
    }
```

### 8. `EditorWindowController.swift`: call it

a. At the end of `editorDidChange(textChanged:)`, after the final `updateStatus()` (line 156), add:

```swift
        updateBotFocus(textChanged ? .edited : .caretMoved)
```

b. In the scroll observer (line 56), change the closure body from:

```swift
            MainActor.assumeIsolated { self?.gutter.needsDisplay = true }
```

to:

```swift
            MainActor.assumeIsolated {
                self?.gutter.needsDisplay = true
                self?.updateBotFocus(.scrolled)
            }
```

c. In `buildLayout(in:)`, right after `bots.isHidden = !BotsOverlay.isEnabled`, add:

```swift
        bots.requestFocus = { [weak self] in self?.updateBotFocus(.caretMoved) }
```

d. In the `BotsOverlay.didToggle` observer just below it, change:

```swift
            MainActor.assumeIsolated { self?.bots.isHidden = !BotsOverlay.isEnabled }
```

to:

```swift
            MainActor.assumeIsolated {
                self?.bots.isHidden = !BotsOverlay.isEnabled
                self?.updateBotFocus(.caretMoved)
            }
```

## Boundaries

- Do NOT touch the other bots' wander timing, colors, blink, bob or morph code beyond steps 3 and 4.
- Do NOT add the v2 design (bigger bots, small eyes, gravity physics). That is separate work.
- Do NOT change `EditorView.swift`. Everything needed (`caretRect(for:)`, `x(ofOffset:)`, `lineTop(_:)`,
  `lineHeight`, `textInsetX`) is already internal and usable from the window controller.
- Do NOT add dependencies.
- If any quoted "current" code doesn't match what you find, STOP and report instead of improvising.

## Verification

- **Mechanical** (from `~/kite`):
  - `swift build` succeeds with no new warnings in `BotsOverlay.swift` or `EditorWindowController.swift`.
  - `swift test` passes all 45 tests.
  - `scripts/bundle.sh && open build/Kite.app --args "$PWD/examples/demo.swift"` launches.
- **Feel check** (in the running app, with `examples/demo.swift`):
  - On launch the star flies to line 1 within about a second and settles just right of `import Foundation`, looking left at the caret.
  - Click on line 10: after a short beat the star flies there with a slight overshoot and settles in about half a second. It lands right of the text, not on it.
  - Hold ↓ from line 1 to line 25: the star does **not** chase each line. It flies once, after you let go.
  - Type a long sentence at the end of line 11: the star stays put until the text reaches it, then hops about six characters ahead. It hops once every few words, never on every keystroke, and never covers a character you just typed.
  - Pause typing on that line: the star does **not** drift back left.
  - Delete most of the line: after you pause, the star moves left to the new end of the text.
  - Scroll with the trackpad: the star rides with its line and doesn't lag or replay a flight. Scroll the line off-screen: the star waits at the top or bottom edge.
  - Click line 3, then line 20 before the first flight lands: it bends toward line 20 mid-air instead of jumping back to start.
  - The other four bots never settle on the edited line's band, about 40 pt above or below it.
  - System Settings ▸ Accessibility ▸ Display ▸ Reduce motion **on**: moving to a new line makes the star fade in at the new spot. Nothing travels across the screen.
  - Slow motion: temporarily add `layer?.speed = 0.2` in `BotsOverlay.init`, rebuild, and watch a flight. It should accelerate out, overshoot slightly and settle, with no jump at the start. Remove that line afterwards.
- **Done when**: every feel check above holds, build and tests pass, and the temporary slow-motion line is gone.
